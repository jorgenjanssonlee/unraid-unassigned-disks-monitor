#!/bin/bash
#name=UD Disk Monitor
#description=Monitor Unassigned Devices mounts for presence and free space; alert via Unraid notifications.
#arrayStarted=true
#
# Repo / instructions:
#   https://github.com/jorgenjanssonlee/unraid-unassigned-disks-monitor
#
# Paste into CA User Scripts. Edit the USER CONFIGURATION section below, then schedule in the UI.
# Usage: monitor_unassigned_disks.sh [--dry-run]
# Optional env: UD_MONITOR_STATE overrides STATE_DIR

PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin
set -euo pipefail

######## USER CONFIGURATION - edit below ########
# On upgrade: copy this whole block into the new script.

# Global defaults
# MODE: percent = alert when used% >= VALUE
#       free_gb = alert when free GiB <= VALUE
WARN_MODE=percent
WARN_VALUE=80
FAIL_MODE=percent
FAIL_VALUE=90

# Alert state directory (RAM on Unraid; cleared on reboot - intentional).
# For persistence across reboots, use a path on the array/cache, e.g.:
# STATE_DIR=/mnt/user/appdata/ud-disk-monitor
STATE_DIR=/var/tmp/ud-disk-monitor

# Unraid syslog (logger): issues = warn/fail/errors only; all = every script message
# User Scripts stdout always logs every run and outcome either way.
SYSLOG_MODE=issues

# Disks to monitor (always-present local/USB mounts).
# Format: "mount|warn_mode|warn_value|fail_mode|fail_value"
# Leave override fields empty to inherit globals.
DISKS=(
  # "/mnt/disks/backup||||"
  # "/mnt/disks/cameras|free_gb|100|free_gb|50"
  # "/mnt/disks/scratch|percent|70|percent|85"
)
######## END USER CONFIGURATION #################

NOTIFY=/usr/local/emhttp/webGui/scripts/notify
LOG_TAG=ud-disk-monitor
DRY_RUN=0

# Always print to stdout (User Scripts log). Syslog depends on SYSLOG_MODE / issue flag.
# Usage: log "message"           - stdout; syslog only if SYSLOG_MODE=all
#        log "message" issue     - stdout + syslog (warn/fail/errors)
log() {
  local msg=$1
  local kind=${2:-}
  echo "$msg"
  if [[ "$kind" == "issue" || "$SYSLOG_MODE" == "all" ]]; then
    logger -t "$LOG_TAG" -- "$msg" 2>/dev/null || true
  fi
}

die() {
  log "ERROR: $1" issue
  exit 1
}

usage() {
  cat <<'EOF'
Usage: monitor_unassigned_disks.sh [--dry-run]

  --dry-run   Print notifications instead of calling Unraid notify
EOF
}

# User Scripts often invokes as: bash script ''  (empty arg) when Run is clicked.
while [[ $# -gt 0 ]]; do
  case "$1" in
    "") shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

config_die() {
  die "Config not OK: $1"
}

validate_config() {
  if [[ -n "${UD_MONITOR_STATE:-}" ]]; then
    STATE_DIR=$UD_MONITOR_STATE
  fi

  validate_mode "$WARN_MODE" || config_die "Invalid WARN_MODE: $WARN_MODE"
  validate_mode "$FAIL_MODE" || config_die "Invalid FAIL_MODE: $FAIL_MODE"
  [[ "$WARN_VALUE" =~ ^[0-9]+$ ]] || config_die "Invalid WARN_VALUE: $WARN_VALUE"
  [[ "$FAIL_VALUE" =~ ^[0-9]+$ ]] || config_die "Invalid FAIL_VALUE: $FAIL_VALUE"

  case "$SYSLOG_MODE" in
    issues|all) ;;
    *) config_die "Invalid SYSLOG_MODE: $SYSLOG_MODE (use issues or all)" ;;
  esac

  [[ ${#DISKS[@]} -gt 0 ]] || config_die "No disks configured - edit the USER CONFIGURATION section (DISKS array)"
  mkdir -p "$STATE_DIR" || config_die "Cannot create STATE_DIR: $STATE_DIR"
  log "Config OK (${#DISKS[@]} disk(s)), state=$STATE_DIR, syslog=$SYSLOG_MODE"
}

validate_mode() {
  case "$1" in
    percent|free_gb) return 0 ;;
    *) return 1 ;;
  esac
}

state_file() {
  local check=$1 mount=$2
  local key
  key=$(printf '%s' "$mount" | tr '/ ' '__')
  echo "$STATE_DIR/${check}${key}"
}

get_state() {
  local f
  f=$(state_file "$1" "$2")
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo ""
  fi
}

set_state() {
  local check=$1 mount=$2 state=$3
  printf '%s\n' "$state" >"$(state_file "$check" "$mount")"
}

send_notify() {
  local importance=$1 subject=$2 description=$3
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN notify -i $importance -s \"$subject\" -d \"$description\""
    return
  fi
  if [[ ! -x "$NOTIFY" ]]; then
    log "notify helper missing ($NOTIFY); subject=$subject desc=$description" issue
    return
  fi
  "$NOTIFY" -e "UD Disk Monitor" -s "$subject" -d "$description" -i "$importance"
}

# On transition: alert when leaving ok/empty for a bad state; recover when returning to ok.
transition() {
  local check=$1 mount=$2 new_state=$3 importance=$4 subject=$5 description=$6
  local prev
  prev=$(get_state "$check" "$mount")

  if [[ "$prev" == "$new_state" ]]; then
    return
  fi

  if [[ "$new_state" == "ok" ]]; then
    if [[ -n "$prev" && "$prev" != "ok" ]]; then
      send_notify "normal" "$subject" "$description"
    fi
  else
    send_notify "$importance" "$subject" "$description"
  fi

  set_state "$check" "$mount" "$new_state"
}

is_mounted() {
  local mount=$1
  findmnt -n --target "$mount" >/dev/null 2>&1
}

# Resolve block device for a mount; empty on failure.
resolve_block_device() {
  local mount=$1 src majmin maj min link name
  src=$(findmnt -n -o SOURCE --target "$mount" 2>/dev/null) || return 1
  if [[ -b "$src" ]]; then
    printf '%s\n' "$src"
    return 0
  fi
  majmin=$(findmnt -n -o MAJ:MIN --target "$mount" 2>/dev/null) || return 1
  maj=${majmin%%:*}
  min=${majmin##*:}
  link="/sys/dev/block/${maj}:${min}"
  [[ -e "$link" ]] || return 1
  name=$(basename "$(readlink -f "$link")")
  [[ -b "/dev/$name" ]] || return 1
  printf '%s\n' "/dev/$name"
}

# Whole-disk node for power-state check (partition -> parent).
whole_disk() {
  local dev=$1 part parent
  part=$(basename "$dev")
  if [[ -e "/sys/class/block/$part/partition" ]]; then
    parent=$(basename "$(readlink -f "/sys/class/block/$part/..")")
    printf '%s\n' "/dev/$parent"
  else
    printf '%s\n' "$dev"
  fi
}

# Returns 0 if disk is spun down / sleeping (skip space check).
# Returns 1 if awake/unknown (proceed with space check - unknown errs toward checking).
disk_is_asleep() {
  local disk=$1 out
  [[ -b "$disk" ]] || return 1
  if ! command -v hdparm >/dev/null 2>&1; then
    return 1
  fi
  # hdparm -C does not issue a media wake for typical ATA standby queries.
  out=$(hdparm -C "$disk" 2>/dev/null) || return 1
  if echo "$out" | grep -Eiq 'drive state is:[[:space:]]*(standby|sleeping)'; then
    return 0
  fi
  return 1
}

# Sets globals: USED_PCT FREE_GIB TOTAL_BYTES FREE_BYTES
read_space() {
  local mount=$1
  local total used avail
  # df can wake a spun-down disk - caller must gate on power state.
  read -r total used avail < <(df -P -B1 "$mount" 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
  [[ -n "${total:-}" && "$total" -gt 0 ]] || return 1
  TOTAL_BYTES=$total
  FREE_BYTES=$avail
  USED_PCT=$(( used * 100 / total ))
  # GiB with integer math (1024^3)
  FREE_GIB=$(( avail / 1024 / 1024 / 1024 ))
}

threshold_breached() {
  local mode=$1 value=$2
  case "$mode" in
    percent)
      [[ "$USED_PCT" -ge "$value" ]]
      ;;
    free_gb)
      [[ "$FREE_GIB" -le "$value" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

effective_fields() {
  # Input: disk line. Sets EFF_MOUNT EFF_WARN_MODE EFF_WARN_VALUE EFF_FAIL_MODE EFF_FAIL_VALUE
  local line=$1
  local m wm wv fm fv
  IFS='|' read -r m wm wv fm fv <<<"$line"
  EFF_MOUNT=$m
  EFF_WARN_MODE=${wm:-$WARN_MODE}
  EFF_WARN_VALUE=${wv:-$WARN_VALUE}
  EFF_FAIL_MODE=${fm:-$FAIL_MODE}
  EFF_FAIL_VALUE=${fv:-$FAIL_VALUE}

  validate_mode "$EFF_WARN_MODE" || config_die "Invalid warn mode for $m: $EFF_WARN_MODE"
  validate_mode "$EFF_FAIL_MODE" || config_die "Invalid fail mode for $m: $EFF_FAIL_MODE"
  [[ "$EFF_WARN_VALUE" =~ ^[0-9]+$ ]] || config_die "Invalid warn value for $m: $EFF_WARN_VALUE"
  [[ "$EFF_FAIL_VALUE" =~ ^[0-9]+$ ]] || config_die "Invalid fail value for $m: $EFF_FAIL_VALUE"
}

check_disk() {
  local line=$1
  local block disk desc

  effective_fields "$line"

  if ! is_mounted "$EFF_MOUNT"; then
    log "$EFF_MOUNT: not mounted" issue
    transition "presence" "$EFF_MOUNT" "missing" "alert" \
      "UD disk not mounted" \
      "$EFF_MOUNT is not mounted"
    return
  fi

  block=$(resolve_block_device "$EFF_MOUNT" || true)
  if [[ -z "$block" || ! -b "$block" ]]; then
    log "$EFF_MOUNT: mounted but block device missing" issue
    transition "presence" "$EFF_MOUNT" "nodevice" "alert" \
      "UD disk device missing" \
      "$EFF_MOUNT is mounted but its block device is gone"
    return
  fi

  transition "presence" "$EFF_MOUNT" "ok" "normal" \
    "UD disk mount recovered" \
    "$EFF_MOUNT is mounted again ($block)"

  disk=$(whole_disk "$block")
  if disk_is_asleep "$disk"; then
    log "$EFF_MOUNT: $disk asleep - skipping space check"
    return
  fi

  if ! read_space "$EFF_MOUNT"; then
    log "$EFF_MOUNT: failed to read free space" issue
    transition "space" "$EFF_MOUNT" "fail" "alert" \
      "UD disk space check failed" \
      "Could not read free space for $EFF_MOUNT"
    return
  fi

  desc="$EFF_MOUNT: ${USED_PCT}% used, ${FREE_GIB} GiB free (device $block)"

  if threshold_breached "$EFF_FAIL_MODE" "$EFF_FAIL_VALUE"; then
    log "$desc - FAIL ($EFF_FAIL_MODE=$EFF_FAIL_VALUE)" issue
    transition "space" "$EFF_MOUNT" "fail" "alert" \
      "UD disk space critical" \
      "$desc (fail threshold $EFF_FAIL_MODE=$EFF_FAIL_VALUE)"
    return
  fi

  if threshold_breached "$EFF_WARN_MODE" "$EFF_WARN_VALUE"; then
    log "$desc - WARN ($EFF_WARN_MODE=$EFF_WARN_VALUE)" issue
    transition "space" "$EFF_MOUNT" "warn" "warning" \
      "UD disk space warning" \
      "$desc (warn threshold $EFF_WARN_MODE=$EFF_WARN_VALUE)"
    return
  fi

  log "$desc - OK"
  transition "space" "$EFF_MOUNT" "ok" "normal" \
    "UD disk space recovered" \
    "$desc"
}

main() {
  validate_config
  local line
  for line in "${DISKS[@]}"; do
    check_disk "$line"
  done
  log "Run complete"
}

main
