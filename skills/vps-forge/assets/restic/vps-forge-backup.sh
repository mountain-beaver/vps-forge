#!/usr/bin/env bash
# vps-forge-backup.sh: restic backup with pre-hooks, healthchecks pings and failure alerts.
#   vps-forge-backup.sh                 back up (daily timer)
#   vps-forge-backup.sh --maintenance   forget/prune + integrity check (weekly timer)
# Config: /etc/restic/env (600), /etc/restic/include, /etc/restic/exclude, /etc/restic/pre.d/*.sh
# Part of vps-forge (MIT).

set -uo pipefail
ENV_FILE=${RESTIC_ENV_FILE:-/etc/restic/env}
INCLUDE=/etc/restic/include
EXCLUDE=/etc/restic/exclude
PRE_DIR=/etc/restic/pre.d
STAMP_DIR=/var/lib/vps-forge/backup
MODE=backup
[[ "${1:-}" == "--maintenance" ]] && MODE=maintenance

[[ -r "$ENV_FILE" ]] || { echo "cannot read $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
export RESTIC_CACHE_DIR=${RESTIC_CACHE_DIR:-/var/cache/restic}

hc() { # ping healthchecks: "" = success, /start, /fail
  [[ -n "${HC_URL:-}" ]] || return 0
  printf 'url = "%s%s"\n' "$HC_URL" "$1" | curl -fsS --max-time 10 --retry 3 -K - -o /dev/null 2>/dev/null || true
}
notify() { [[ -x /usr/local/bin/vps-notify ]] && /usr/local/bin/vps-notify "$1" "$2" "${3:-high}" >/dev/null 2>&1; return 0; }
die() {
  echo "ERROR: $1" >&2
  hc /fail
  notify "Backup FAILED" "$(hostname) restic $MODE: $1. See: journalctl -u vps-forge-backup*"
  exit 1
}

# Backup and maintenance must not overlap: prune takes an exclusive repository lock, so the
# second job would fail. Wait for the other one, but not forever.
# The lock lives in a root-only directory (not world-writable /run/lock, where a local user
# could plant a symlink or squat the lock) and is opened without truncating anything.
LOCK_DIR=/run/vps-forge
LOCK=$LOCK_DIR/backup.lock
install -d -m 700 -o root -g root "$LOCK_DIR" || die "cannot create $LOCK_DIR"
[[ -L "$LOCK_DIR" || -L "$LOCK" ]] && die "refusing to use a symlinked lock ($LOCK)"
exec 9<>"$LOCK" || die "cannot open lock $LOCK"
if ! flock -n 9; then
  echo "waiting for the other vps-forge backup job (lock $LOCK)"
  flock -w "${LOCK_WAIT:-7200}" 9 || die "another backup/maintenance run still holds $LOCK after ${LOCK_WAIT:-7200}s"
fi

if [[ "$MODE" == "maintenance" ]]; then
  hc /start
  restic unlock || true    # removes only stale locks
  restic forget --prune \
    --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-12}" \
    || die "forget/prune failed"
  restic check --read-data-subset="${CHECK_SUBSET:-5%}" || die "repository check FAILED (possible corruption)"
  hc ""
  exit 0
fi

hc /start

# 1) pre-hooks (database dumps etc.): any failure fails the backup
if [[ -d "$PRE_DIR" ]]; then
  for h in "$PRE_DIR"/*.sh; do
    [[ -e "$h" ]] || continue
    echo "pre-hook: $h"
    bash "$h" 9>&- || die "pre-hook $(basename "$h") failed"
  done
fi

# 2) only back up paths that exist (restic errors on missing ones)
fstab_mounts() { # path -> /etc/fstab mountpoints at or below path, one per line
  [[ -r /etc/fstab ]] || return 0
  awk -v p="$1" '
    $1 ~ /^#/ || NF < 3 || $3 == "swap" || $2 == "none" { next }
    {
      m = $2; gsub(/\\040/, " ", m); if (m != "/") sub(/\/+$/, "", m)
      if (m == p) { print m; next }
      # A noauto child is mounted on demand (or by hand): not expected to be up.
      if ($4 ~ /(^|,)noauto(,|$)/) next
      if (p == "/" || index(m, p "/") == 1) print m
    }' /etc/fstab
}
list=$(mktemp); trap 'rm -f "$list"' EXIT
while IFS= read -r p; do
  [[ -z "$p" || "$p" == \#* ]] && continue
  [[ "$p" != / ]] && p=${p%/}
  [[ -e "$p" ]] || continue
  # An fstab volume that failed to mount leaves an empty directory behind; backing that up
  # would produce a green snapshot with none of the data. That holds for the path itself and
  # for any volume below it (/srv/data under an included /srv).
  unmounted=""
  while IFS= read -r m; do
    [[ -n "$m" ]] && ! mountpoint -q "$m" && unmounted+=" $m"
  done < <(fstab_mounts "$p")
  [[ -z "$unmounted" ]] || die "in /etc/fstab but not mounted:$unmounted (included via $p)"
  echo "$p" >> "$list"
done < "$INCLUDE"
[[ -s "$list" ]] || die "nothing to back up (check $INCLUDE)"

# 3) backup
restic backup --files-from "$list" --exclude-file "$EXCLUDE" --exclude-caches --tag vps-forge
rc=$?
stamp() { # name: Read by vps-forge-health (install-alerts.sh --health), which alerts when the backups get too old.
  { install -d -m 755 "$STAMP_DIR" && date +%s > "$STAMP_DIR/$1.tmp" && mv -f "$STAMP_DIR/$1.tmp" "$STAMP_DIR/$1"; } \
    || echo "WARNING: cannot write $STAMP_DIR/$1; the health check may report the backup as overdue" >&2
}
case $rc in
  0) hc ""; echo "backup OK"
     rm -f "$STAMP_DIR/last-partial"
     stamp last-success ;;
  3) # Exit 3: the snapshot WAS created, but restic could not read some source files (EACCES, EIO
     # and the like). Files that vanish during the run are skipped silently and do not cause this.
     # That is a warning to act on, not a failed backup: the unit stays green, last-partial is
     # stamped (not last-success), and the alert is a normal-priority WARNING.
     echo "WARNING: backup incomplete (restic exit 3): snapshot saved, but some files could not be read" >&2
     hc ""
     notify "Backup WARNING" "$(hostname): restic saved a snapshot but could not read some files (permissions or I/O errors). See: journalctl -u vps-forge-backup" default
     stamp last-partial ;;
  *) die "restic backup exit $rc" ;;
esac
exit 0
