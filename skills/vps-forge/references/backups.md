# Backups

A backup only counts once a restore has been tested. Say so, and do the test.

## Contents
- Layers
- restic setup
- What to include
- Deletion resistance
- Maintenance
- Restore drill

## Layers

1. **Provider snapshots/backups.** These capture the whole disk and are fast to roll back, but they live at the same provider and in the same account. Ask the user to enable them; they can't be detected from inside the VM.
2. **restic to off-site object storage.** Encrypted, deduplicated, versioned, and independent of the provider. This is the real backup.
3. **For paranoid:** a second restic repository at a different provider, or a pull-based copy from another machine.

## restic setup

Storage options the user is likely to have: Backblaze B2 (S3 API), Cloudflare R2, Hetzner Storage Box (`sftp:` on port 23), AWS S3, Wasabi, or a `rest-server` on another box.

```bash
$APT install restic
install -d -m 700 /etc/restic /var/backups/db
( umask 077; openssl rand -base64 48 > /etc/restic/password )   # born 600: no window where it is readable
```
**The user must save the repository password offline right now.** Without it the backups are unreadable, and it dies with the server. Point them to the file (`/etc/restic/password`). Don't print it into chat, unless they ask you to display it so they can copy it into a password manager.

Copy the assets:
- `assets/restic/env.example` → `/etc/restic/env` (600; create it private with `( umask 077; cat > /etc/restic/env )` or `install -m 600 /dev/null /etc/restic/env` before the credentials go in): `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, storage credentials, optional `HC_URL` (healthchecks.io ping).
- `assets/restic/include` and `exclude` → `/etc/restic/`
- `assets/restic/vps-forge-backup.sh` → `/usr/local/sbin/` (755)
- `assets/restic/vps-forge-backup.{service,timer}` and `vps-forge-backup-maint.{service,timer}` → `/etc/systemd/system/`
- DB dump hooks go in `/etc/restic/pre.d/*.sh` (databases.md). The script runs them in order, and a failing hook fails the backup.

Then:
```bash
set -a; . /etc/restic/env; set +a; restic init      # once
systemctl daemon-reload && systemctl enable --now vps-forge-backup.timer vps-forge-backup-maint.timer
systemctl start vps-forge-backup.service && journalctl -u vps-forge-backup -n 30 --no-pager
restic snapshots
```
For Hetzner Storage Box over SFTP, the repository is `sftp:uXXXX@uXXXX.your-storagebox.de:/backups/<host>`. Root needs an SSH key in the box's `.ssh/authorized_keys` and a `Host` entry with `Port 23` in `/root/.ssh/config`.

## What to include

The default `include` covers: `/etc`, `/root`, `/home`, `/opt`, `/srv`, `/var/backups`, `/var/lib/caddy`, `/var/spool/cron`, `/usr/local`.

Excluded: caches, `node_modules`, `.cache`, Docker's image and overlay storage, live database data directories (dumps are backed up instead).

Docker named volumes (`/var/lib/docker/volumes`): prefer bind mounts under `/opt/<app>/data`. If named volumes hold state, add them to the include list and stop the container or dump it first, because copying files under a live database is not a backup.

## Deletion resistance (hardened+)

If an attacker gets root on the server, they hold the repo credentials and can delete every snapshot. Pick one of these:
- **Object Lock** (S3, B2, Wasabi; R2 bucket locks): objects can't be deleted or overwritten for the retention period, even with the server's key. Set retention a little longer than your `forget` window. This is the strongest option.
- **Versioning plus a key that can't delete versions.** A versioned bucket alone is **not** enough: a key that may delete object versions can wipe history too. Give the server a key without permanent-delete rights (B2: application key without `deleteFiles`, so deletes only hide files; S3: deny `s3:DeleteObjectVersion` in the policy), and let a lifecycle rule expire hidden or noncurrent versions after 30+ days. After switching keys, run one backup and one `restic forget` to confirm restic still works with them.
- **Append-only rest-server** on a separate machine (`rest-server --append-only`). The server can add snapshots but not remove them. In this mode `forget/prune` must run from a trusted machine, so disable `vps-forge-backup-maint.timer` on the VPS.
- Note the choice in SERVER.md, along with who runs prune.

## Maintenance

`vps-forge-backup-maint.timer` (weekly) runs `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune` and `restic check --read-data-subset=5%`. Adjust the retention to the user's needs and storage budget.

restic exit codes: **1** is a failed backup (unit fails, "Backup FAILED"). **3** means the snapshot was created but restic could not read some files (permissions, I/O errors; files that vanish during the run are skipped silently). The script treats 3 as a warning: the unit stays green, it sends "Backup WARNING", and it writes `/var/lib/vps-forge/backup/last-partial` instead of `last-success`. Find the files in `journalctl -u vps-forge-backup`, then fix their permissions or exclude them. An unmounted fstab volume under an included path stops the run before restic starts, so an empty directory never becomes a green snapshot.

Monitoring: `vps-forge-health` (alerts-monitoring.md) alerts when the last backup is older than `BACKUP_MAX_AGE_HOURS` (36), even without healthchecks.io. A partial backup counts as recent for this check, because the warning above already fires every run. On top of that, set `HC_URL` to a healthchecks.io check with a 1-day period and 6-hour grace. The script pings `/start`, success and `/fail`, so a silent failure becomes an alert (alerts-monitoring.md).

## Restore drill

Do this before calling the phase done:
Restore what the user would actually miss: a file of the app's data and the newest database dump, not a config file.
```bash
set -a; . /etc/restic/env; set +a
restic snapshots --latest 1
APP=/opt/<app>/data                     # the app's data directory or bind mount; ask if unsure
F=$(find "$APP" -type f -size +0 -mmin +10 2>/dev/null | head -n 1)   # unchanged since the backup ran
DUMP=$(ls -t /var/backups/db/* 2>/dev/null | head -n 1)
[ -n "$F" ] || echo "no stable data file under $APP: pick one by hand"
rm -rf /root/restore-test && restic restore latest --target /root/restore-test --include "$F" ${DUMP:+--include "$DUMP"}
cmp "$F" "/root/restore-test$F" && echo "app data restored: $F"
[ -z "$DUMP" ] || { cmp "$DUMP" "/root/restore-test$DUMP" && echo "dump restored: $DUMP"; }
rm -rf /root/restore-test
```
Then load that dump into a scratch database and count a few rows (databases.md). A restore of `/etc` alone proves that restic works, not that the app's data comes back.

Write the full recovery procedure into SERVER.md: where the repo is, where the password is, how to install restic on a fresh box, and the exact restore command.
