# Unraid Unassigned Disks Monitor

User Scripts helper that watches **Unassigned Devices** mounts Unraid does not cover with its built-in disk-space alerts.

It periodically checks that a configured mount is present and (when the disk is awake) that free space is within warn/fail thresholds, then notifies through Unraid’s built-in `notify` system (GUI, email, Discord, etc. — whatever you enabled under **Settings → Notifications**).

License: [MIT-0](LICENSE) (use freely; no attribution required).

## What it checks

| Check | Behavior |
| --- | --- |
| **Presence** | Mount path is an active mount **and** its block device node still exists |
| **Space** | Used % or free GiB vs warn/fail thresholds |
| **Spin-down** | If the disk is in standby/sleep (`hdparm -C`), **space is skipped** so the check does not wake it. Presence is still checked (no media I/O). |

Out of scope: SMART, temperature, remote SMB/NFS Unassigned Devices shares, scheduling inside the script.

## Install (User Scripts)

1. Install **CA User Scripts** from Community Applications (if needed).
2. Create a new script (e.g. name: `UD Disk Monitor`).
3. Paste the contents of [`monitor_unassigned_disks.sh`](monitor_unassigned_disks.sh) into the script body (or keep the file on the flash and call it — see below).
4. Copy the example config onto the flash:

   ```bash
   cp /path/to/config.example /boot/config/ud-disk-monitor.conf
   nano /boot/config/ud-disk-monitor.conf
   ```

5. Add one line per always-present mount (see [Configuration](#configuration)).
6. In User Scripts, set a **Custom** schedule, for example every 15 minutes:

   ```cron
   */15 * * * *
   ```

7. Confirm notification agents are enabled under **Settings → Notifications**.
8. First test from an Unraid shell with `--dry-run` (no notifications sent):

   ```bash
   bash /boot/config/plugins/ud-disk-monitor/monitor_unassigned_disks.sh --dry-run
   ```

### Recommended: keep repo files on the flash

```bash
mkdir -p /boot/config/plugins/ud-disk-monitor
# copy monitor_unassigned_disks.sh + config.example into that directory, then:
cp /boot/config/plugins/ud-disk-monitor/config.example /boot/config/ud-disk-monitor.conf
nano /boot/config/ud-disk-monitor.conf
```

User Scripts body:

```bash
#!/bin/bash
bash /boot/config/plugins/ud-disk-monitor/monitor_unassigned_disks.sh "$@"
```

## Configuration

Default config path: `/boot/config/ud-disk-monitor.conf`  
Override with env `UD_MONITOR_CONFIG=/path/to/config`.

```bash
WARN_MODE=percent
WARN_VALUE=80
FAIL_MODE=percent
FAIL_VALUE=90

# mount|warn_mode|warn_value|fail_mode|fail_value
# Empty fields inherit globals.
/mnt/disks/backup||||
/mnt/disks/cameras|free_gb|100|free_gb|50
```

| Mode | Meaning |
| --- | --- |
| `percent` | Alert when **used %** ≥ value |
| `free_gb` | Alert when **free GiB** ≤ value |

Fail supersedes warn when both would match.

Only monitor disks that should **always** be present (local or always-plugged USB). Removable media you intentionally unplug will alert as missing.

## Alerts and state

- Uses `/usr/local/emhttp/webGui/scripts/notify` with importance `warning` / `alert`, and `normal` on recovery.
- State is stored under `/var/tmp/ud-disk-monitor/` (override with `STATE_DIR=` in config or `UD_MONITOR_STATE`).
- On Unraid this path is **RAM-backed and cleared on reboot**. That is intentional:
  - During uptime: notify only on **transitions** (no spam every cron tick).
  - After reboot: if a disk is still bad, you get **one new alert**; if healthy, no recovery notice.
- To keep state across reboots (usually unnecessary), point `STATE_DIR` at a persistent path.

Syslog tag: `ud-disk-monitor` (`logger -t ud-disk-monitor`).

## Maintenance

- **Add/remove a disk:** edit `/boot/config/ud-disk-monitor.conf`, add or delete a mount line.
- **Tune thresholds:** change globals or per-disk overrides; next run uses the new values (state is severity name only, not the threshold number).
- **Clear sticky state without reboot:** `rm -rf /var/tmp/ud-disk-monitor`
- **Cold disks:** presence still monitored; low-space alerts wait until the disk is awake for real work (or until something else spins it up).

## Dry run

```bash
bash monitor_unassigned_disks.sh --dry-run
```

Prints what would be sent instead of calling `notify`.
