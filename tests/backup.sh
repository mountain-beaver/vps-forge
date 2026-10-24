#!/usr/bin/env bash
# vps-forge-backup.sh against stub restic, mountpoint and vps-notify. The script is copied with its
# absolute paths rewritten into a temp dir, so nothing touches the real /etc, /var or /run.
# Usage: tests/backup.sh (no root needed; needs flock from util-linux).
set -euo pipefail
cd "$(dirname "$0")/.."
SKILL=skills/vps-forge
fail=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/srv/data" "$T/home"

sed -e "s#/etc/restic/include#$T/include#g" -e "s#/etc/restic/exclude#$T/exclude#g" \
    -e "s#/etc/restic/pre.d#$T/pre.d#g" -e "s#/var/lib/vps-forge/backup#$T/stamps#g" \
    -e "s#/run/vps-forge#$T/run#g" -e "s#/usr/local/bin/vps-notify#$T/bin/vps-notify#g" \
    -e "s#/etc/fstab#$T/fstab#g" -e 's# -o root -g root##' \
    "$SKILL/assets/restic/vps-forge-backup.sh" > "$T/backup.sh"
if grep -vE '^[[:space:]]*#|RESTIC_(ENV_FILE|CACHE_DIR)' "$T/backup.sh" | grep -nE '(^|[^A-Za-z0-9_$])/(etc|var|run|usr/local)/'; then
  bad "the rewritten backup script still names a real path"; exit 1
fi

cat > "$T/bin/restic" <<STUB
#!/bin/sh
echo "restic \$*" >> "$T/calls.log"
[ "\$1" = backup ] && exit "\${STUB_RESTIC_RC:-0}"
exit 0
STUB
cat > "$T/bin/mountpoint" <<STUB
#!/bin/sh
for a in "\$@"; do m=\$a; done
grep -qxF "\$m" "$T/mounted" 2>/dev/null
STUB
cat > "$T/bin/vps-notify" <<STUB
#!/bin/sh
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T/notify.log"
STUB
chmod +x "$T"/bin/*
printf 'RESTIC_REPOSITORY=/nonexistent\nRESTIC_PASSWORD_FILE=/nonexistent\n' > "$T/env"
: > "$T/exclude"

reset() {
  rm -rf "$T/stamps" "$T/run" "$T/calls.log" "$T/notify.log" "$T/mounted"
  : > "$T/calls.log"; : > "$T/notify.log"
  printf '%s\n' "$T/srv" > "$T/include"
  : > "$T/fstab"
}
run() { # restic-exit-code
  STUB_RESTIC_RC=$1 RESTIC_ENV_FILE=$T/env RESTIC_CACHE_DIR=$T/cache LOCK_WAIT=5 PATH="$T/bin:$PATH" \
    bash "$T/backup.sh" >"$T/out.log" 2>&1 && rc=0 || rc=$?
}
restic_backups() { grep -c '^restic backup' "$T/calls.log" || true; }

reset
run 0
if [[ $rc -eq 0 && $(restic_backups) -eq 1 && -s $T/stamps/last-success && ! -e $T/stamps/last-partial ]] && ! grep -q . "$T/notify.log"; then
  ok "restic exit 0: success, last-success stamped, no alert"
else
  bad "restic exit 0 (rc=$rc): $(ls "$T/stamps" 2>&1 | tr '\n' ' ') / $(head -n 2 "$T/out.log" | tr '\n' '/')"
fi

reset
run 3
if [[ $rc -eq 0 && -s $T/stamps/last-partial && ! -e $T/stamps/last-success ]] \
   && grep -q '^Backup WARNING|.*|default$' "$T/notify.log" && ! grep -q 'FAILED' "$T/notify.log"; then
  ok "restic exit 3: unit succeeds, last-partial stamped, WARNING (not FAILED), no last-success"
else
  bad "restic exit 3 (rc=$rc): $(ls "$T/stamps" 2>&1 | tr '\n' ' ') / $(tr '\n' '/' < "$T/notify.log")"
fi
# a later complete backup clears the partial marker and stamps success
run 0
if [[ $rc -eq 0 && -s $T/stamps/last-success && ! -e $T/stamps/last-partial ]]; then
  ok "a full backup after a partial one clears last-partial"
else
  bad "stamps after partial -> success: $(ls "$T/stamps" 2>&1 | tr '\n' ' ')"
fi

reset
run 1
if [[ $rc -eq 1 ]] && grep -q '^Backup FAILED|' "$T/notify.log" && [[ ! -e $T/stamps/last-success && ! -e $T/stamps/last-partial ]]; then
  ok "restic exit 1: failure, Backup FAILED alert, no stamps"
else
  bad "restic exit 1 (rc=$rc): $(tr '\n' '/' < "$T/notify.log")"
fi

reset
printf '/dev/vdb1 %s/srv/data ext4 defaults 0 2\n' "$T" > "$T/fstab"
run 0
if [[ $rc -eq 1 && $(restic_backups) -eq 0 && ! -e $T/stamps/last-success ]] \
   && grep -q 'in .*fstab but not mounted: .*srv/data' "$T/out.log" && grep -q '^Backup FAILED|' "$T/notify.log"; then
  ok "an unmounted child mount: die before restic runs"
else
  bad "unmounted child mount (rc=$rc, restic backups: $(restic_backups)): $(head -n 3 "$T/out.log" | tr '\n' '/')"
fi
printf '%s\n' "$T/srv/data" > "$T/mounted"
run 0
if [[ $rc -eq 0 && $(restic_backups) -eq 1 ]]; then
  ok "the same child mount, mounted: the backup runs"
else
  bad "mounted child (rc=$rc): $(head -n 3 "$T/out.log" | tr '\n' '/')"
fi
reset
printf '/dev/vdb1 %s/srv/data ext4 noauto,defaults 0 2\n' "$T" > "$T/fstab"
run 0
if [[ $rc -eq 0 && $(restic_backups) -eq 1 ]]; then
  ok "a noauto child mount that is not mounted is not an error"
else
  bad "noauto child (rc=$rc): $(head -n 3 "$T/out.log" | tr '\n' '/')"
fi

echo
if (( fail )); then echo "BACKUP TESTS FAILED"; exit 1; fi
echo "BACKUP TESTS PASSED"
