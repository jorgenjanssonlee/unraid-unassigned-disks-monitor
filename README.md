# Unraid Unassigned Disks Monitor

A **User Scripts** helper that monitors **Unassigned Devices** mounts for free space and presence. Unraid's built-in disk alerts do not cover these mounts.

It periodically checks that a configured mount is present and (when the disk is awake) that free space is within warn/fail thresholds, then alerts through Unraid's built-in notification system.

License: [MIT-0](LICENSE) (use freely; no attribution required).

## What it checks


| Check         | Behavior                                                                                                                                     |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Presence**  | Mount path is an active mount **and** its block device node still exists                                                                     |
| **Space**     | Used % or free GiB vs warn/fail thresholds                                                                                                   |
| **Spin-down** | If the disk is in standby/sleep (`hdparm -C`), **space is skipped** so the check does not wake it. Presence is still checked (no media I/O). |


Out of scope: SMART, temperature, remote SMB/NFS Unassigned Devices shares, scheduling inside the script.

## Prerequisites

Install from Community Applications if needed, then configure in the Unraid UI:

- **Unassigned Devices** - disks/mounts to monitor should already be set up
- **User Scripts** (CA User Scripts)
- **Notifications** under **Settings → Notifications** (enable whatever agents you want: GUI, email, Discord, etc.)

## Install

1. Open **Settings → User Scripts** and add a new script.
  - **Name:** `UD Disk Monitor`
  - **Description:** `Monitor Unassigned Devices disks/mounts for presence and free space; alert via Unraid notifications.`
2. Edit the script and paste in the full contents of [`monitor_unassigned_disks.sh`](monitor_unassigned_disks.sh).
3. In the **USER CONFIGURATION** section near the top, set global thresholds and uncomment/add your mounts in the `DISKS` array - see [Configuration](#configuration).
4. Set the schedule to **Custom**, for example every 30 minutes: `*/30 * * * *`
5. Use **Run Script** once to confirm it works. Check Unraid notifications and the User Scripts log output.

Optional dry-run (no notifications): from a terminal,
`bash /boot/config/plugins/user.scripts/scripts/UD\ Disk\ Monitor/script --dry-run`
(adjust the folder name if you used a different script name).

## Configuration

All settings live in the **USER CONFIGURATION** block inside the script (edit in the User Scripts UI).

**Mount path from Unassigned Devices:** on the Unraid **Main** page, find the device under **Unassigned Devices** and copy its **Mount Point** (usually `/mnt/disks/<name>` when mounted). Use that exact path in the `DISKS` array.

```bash
WARN_MODE=percent
WARN_VALUE=80
FAIL_MODE=percent
FAIL_VALUE=90
STATE_DIR=/var/tmp/ud-disk-monitor
SYSLOG_MODE=issues   # issues = warn/fail/errors only; all = every message

DISKS=(
  "/mnt/disks/backup||||"
  "/mnt/disks/cameras|free_gb|100|free_gb|50"
)
```

Disk line format: `mount|warn_mode|warn_value|fail_mode|fail_value`  
Empty override fields inherit the globals.


| Mode      | Meaning                         |
| --------- | ------------------------------- |
| `percent` | Alert when **used %** ≥ value   |
| `free_gb` | Alert when **free GiB** ≤ value |


Fail supersedes warn when both would match.

Only monitor disks that should **always** be present (local or always-plugged USB). Removable media you intentionally unplug will alert as missing.

## Alerts and state

- Uses `/usr/local/emhttp/webGui/scripts/notify` with importance `warning` / `alert`, and `normal` on recovery.
- State is stored under `/var/tmp/ud-disk-monitor/` (change `STATE_DIR` in the script, or set env `UD_MONITOR_STATE`).
- On Unraid this path is **RAM-backed and cleared on reboot**. That is intentional:
  - During uptime: notify only on **transitions** (no spam every cron tick).
  - After reboot: if a disk is still bad, you get **one new alert**; if healthy, no recovery notice.
- To keep state across reboots (usually unnecessary), point `STATE_DIR` at a persistent path.

**Logging**

- **User Scripts log** (stdout): every run - config summary, per-disk OK/skip/warn/fail, run complete.
- **Unraid syslog** (`logger -t ud-disk-monitor`): controlled by `SYSLOG_MODE`
  - `issues` (default) - warn/fail/missing, config not OK, and other errors
  - `all` - same messages as the script log



## Maintenance

- **Add/remove a disk or tune thresholds:** edit the USER CONFIGURATION section in User Scripts. Changes apply on the next run.
- **Upgrade the script:** paste the new script, then copy your USER CONFIGURATION block back in.
- **Clear sticky alert state without reboot:** delete `/var/tmp/ud-disk-monitor` (file manager or terminal).
- **Cold disks:** presence is still monitored; low-space alerts wait until the disk wakes for real work.

## Check logic

Per configured mount path:

```mermaid
flowchart TD
  start[For each mount path] --> mounted{Mounted via findmnt?}
  mounted -->|no| alertMissing[Alert: not mounted]
  mounted -->|yes| device{Device node exists?}
  device -->|no| alertDevice[Alert: device missing]
  device -->|yes| power{Disk awake?}
  power -->|asleep| skipSpace[Skip space check]
  power -->|awake| space[df space check]
  space --> thresh{Warn or fail?}
  thresh -->|fail| alertFail[Notify alert]
  thresh -->|warn| alertWarn[Notify warning]
  thresh -->|ok| clearSpace[Clear space state]
  skipSpace --> endNode[Next disk]
  alertMissing --> endNode
  alertDevice --> endNode
  alertFail --> endNode
  alertWarn --> endNode
  clearSpace --> endNode
```

