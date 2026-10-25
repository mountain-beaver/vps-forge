#!/usr/bin/env bash
# vps-forge-health (the heredoc inside install-alerts.sh) against stub vps-notify, df, systemctl,
# journalctl and date. Nothing here touches the real /etc or /var: the script is extracted and its
# absolute paths are rewritten into a temp dir. Usage: tests/alerts.sh (no root needed).
set -euo pipefail
cd "$(dirname "$0")/.."
SKILL=skills/vps-forge
INSTALLER=$SKILL/scripts/install-alerts.sh
fail=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/backup"

# ---- extraction: the health script, with every absolute path moved under $T
awk '/cat > \/usr\/local\/sbin\/vps-forge-health <<.EOF./{f=1; next} f&&/^EOF$/{exit} f' "$INSTALLER" \
  | sed -e "s#/etc/vps-forge/notify.env#$T/notify.env#g" \
        -e "s#/var/lib/vps-forge/alerts#$T/state#g" \
        -e "s#/usr/local/bin/vps-notify#$T/bin/vps-notify#g" \
        -e "s#/etc/restic/env#$T/restic-env#g" \
        -e "s#/etc/systemd/system/vps-forge-backup.timer#$T/backup.timer#g" \
        -e "s#/var/lib/vps-forge/backup#$T/backup#g" \
        -e "s#/var/run/reboot-required#$T/reboot-required#g" > "$T/health.sh"
[[ -s "$T/health.sh" ]] || { bad "could not extract vps-forge-health from $INSTALLER"; exit 1; }
if grep -vE '^[[:space:]]*#' "$T/health.sh" | grep -nE '(^|[^A-Za-z0-9_$])/(etc|var|usr/local)/'; then
  bad "the extracted health script still names a real path (the test would touch the host)"; exit 1
fi

# ---- stubs
cat > "$T/bin/vps-notify" <<STUB
#!/bin/sh
rc=0; [ -f "$T/notify.rc" ] && rc=\$(cat "$T/notify.rc")
[ "\$rc" = 0 ] && printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T/sent.log"
exit "\$rc"
STUB
cat > "$T/bin/systemctl" <<STUB
#!/bin/sh
case "\$*" in
  *--failed*) cat "$T/failed.txt" 2>/dev/null; exit 0 ;;
  show*) cat "$T/show.txt" 2>/dev/null; exit 0 ;;
esac
exit 0
STUB
cat > "$T/bin/df" <<STUB
#!/bin/sh
case "\$*" in *-i*) cat "$T/df-inodes.txt" ;; *) cat "$T/df.txt" ;; esac
STUB
cat > "$T/bin/journalctl" <<STUB
#!/bin/sh
[ -f "$T/journal.rc" ] && exit "\$(cat "$T/journal.rc")"
cat "$T/journal.txt" 2>/dev/null; exit 0
STUB
# date: "now" is whatever the test says; everything else (date -d …) is the real date.
REAL_DATE=$(command -v date)
cat > "$T/bin/date" <<STUB
#!/bin/sh
if [ "\$*" = "+%s" ]; then echo "\$STUB_NOW"; exit 0; fi
exec "$REAL_DATE" "\$@"
STUB
chmod +x "$T"/bin/*

DF_HEAD='Filesystem 1024-blocks Used Available Capacity Mounted on'
healthy() { printf '%s\n/dev/sda1 100 10 90 10%% /\n' "$DF_HEAD" > "$T/df.txt"; printf '%s\n/dev/sda1 100 10 90 10%% /\n' "$DF_HEAD" > "$T/df-inodes.txt"; : > "$T/failed.txt"; : > "$T/journal.txt"; rm -f "$T/journal.rc" "$T/notify.rc" "$T/show.txt"; }
reset() { rm -rf "$T/state" "$T/backup" "$T/sent.log" "$T/reboot-required" "$T/restic-env" "$T/backup.timer"; mkdir -p "$T/state" "$T/backup"; healthy; }
run() { # NOW
  STUB_NOW=$1 PATH="$T/bin:$PATH" bash "$T/health.sh" >"$T/out.log" 2>&1 || { bad "health script exited non-zero: $(head -n 3 "$T/out.log")"; }
}
count() { # pattern -> number of matching lines in the sent log
  if [[ -f "$T/sent.log" ]]; then grep -c -- "$1" "$T/sent.log" || true; else echo 0; fi
}
expect() { # description, expected count, pattern
  local got; got=$(count "$3")
  if [[ "$got" == "$2" ]]; then ok "$1"; else bad "$1 (wanted $2 x '$3', got $got; log: $(tr '\n' '/' 2>/dev/null < "$T/sent.log"))"; fi
}

T0=1800000000   # arbitrary fixed "now"
FAILED='broken.service loaded failed failed Broken thing'

echo "== failed units: dedup, resolve, anti-flap"
reset
echo "$FAILED" > "$T/failed.txt"
run $T0; run $((T0+300)); run $((T0+600))
expect "3 runs with the same failed unit send 1 alert" 1 '^Failed services|'
: > "$T/failed.txt"
run $((T0+900))
expect "the fix sends Resolved" 1 '^Resolved: failed-units|'
echo "$FAILED" > "$T/failed.txt"
run $((T0+1200))
expect "a refail 5 min after the fix stays silent (anti-flap)" 1 '^Failed services|'
run $((T0+1800))
expect "a refail still there 15 min after the fix alerts again (no 6 h wait)" 2 '^Failed services|'
run $((T0+2100))
expect "and then it is deduplicated again" 2 '^Failed services|'

echo "== a failing vps-notify must not record state"
reset
echo "$FAILED" > "$T/failed.txt"; echo 1 > "$T/notify.rc"
run $T0
if [[ ! -e "$T/state/failed-units" && ! -e "$T/state/.sent/failed-units" ]]; then ok "notify failure: no state written"; else bad "notify failure left state behind: $(ls -A "$T/state" "$T/state/.sent" | tr '\n' ' ')"; fi
rm -f "$T/notify.rc"
run $((T0+300))
expect "the alert is retried on the next run" 1 '^Failed services|'

echo "== disk keeps the full cooldown"
reset
printf '%s\n/dev/sda1 100 95 5 95%% /\n' "$DF_HEAD" > "$T/df.txt"
run $T0
expect "disk alert" 1 '^Disk 95% full|'
healthy; run $((T0+300))
expect "disk resolved" 1 '^Resolved: disk_|'
printf '%s\n/dev/sda1 100 95 5 95%% /\n' "$DF_HEAD" > "$T/df.txt"
run $((T0+1800))
expect "a disk refail inside REALERT_HOURS stays silent" 1 '^Disk 95% full|'
run $((T0+7*3600))
expect "...and alerts after the cooldown" 2 '^Disk 95% full|'

echo "== df and journal behaviour"
reset
printf '%s\n' "$DF_HEAD" > "$T/df.txt"; : > "$T/df-inodes.txt"
mkdir -p "$T/state" && echo "$T0 s1:aaaaaaaaaaaa" > "$T/state/disk_"
run $T0
expect "an empty df result does not resolve a disk alert" 0 '^Resolved: disk_'
reset
if grep -q 'timeout 20 df -P' "$T/health.sh" && grep -q 'timeout 20 df -iP' "$T/health.sh"; then ok "df calls run under timeout 20"; else bad "df is not wrapped in timeout 20"; fi

echo "== OOM kills"
OOM1='Oct 23 10:00:01 host kernel: Out of memory: Killed process 4242 (java) total-vm:9000kB, anon-rss:8000kB'
OOM2='Oct 23 10:04:30 host kernel: Out of memory: Killed process 4243 (node) total-vm:9000kB, anon-rss:8000kB'
reset
echo "$OOM1" > "$T/journal.txt"
run $T0; run $((T0+300)); run $((T0+600))
expect "one OOM kill seen in 3 overlapping windows sends 1 alert" 1 '^Out of memory'
printf '%s\n%s\n' "$OOM1" "$OOM2" > "$T/journal.txt"; run $((T0+900))
expect "a second kill alerts" 2 '^Out of memory'
echo "$OOM2" > "$T/journal.txt"; run $((T0+1200))
expect "the first kill ageing out of the window does not re-alert" 2 '^Out of memory'
: > "$T/journal.txt"; run $((T0+1500))
expect "no 'Resolved' message for an event" 0 '^Resolved: oom'
echo 1 > "$T/journal.rc"; echo "$OOM2" > "$T/journal.txt"; run $((T0+1800))
expect "an unreadable journal sends nothing" 2 '^Out of memory'
reset
echo "$OOM1" > "$T/journal.txt"; echo 1 > "$T/notify.rc"; run $T0; rm -f "$T/notify.rc"; run $((T0+300))
expect "an OOM alert that failed to send is retried" 1 '^Out of memory'

echo "== overdue backup"
reset
touch "$T/restic-env" "$T/backup.timer"
NOW=$((T0+100*3600))
touch -d "@$T0" "$T/restic-env"
run $NOW
expect "no stamp, old restic setup: overdue" 1 '^Backup overdue|'
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
echo $((NOW-3600)) > "$T/backup/last-success"; run $NOW
expect "a fresh last-success is fine" 0 '^Backup overdue|'
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
echo $((NOW-90*3600)) > "$T/backup/last-success"; echo $((NOW-3600)) > "$T/backup/last-partial"; run $NOW
expect "a recent partial backup counts as a backup" 0 '^Backup overdue|'
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
echo $((NOW-90*3600)) > "$T/backup/last-success"; echo $((NOW-80*3600)) > "$T/backup/last-partial"; run $NOW
expect "an old partial and an old success are overdue" 1 '^Backup overdue|'
# systemd fallback: no --timestamp=unix; the human-readable timestamp is parsed with date -d
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
ts=$("$REAL_DATE" -u -d "@$((NOW-3600))" '+%a %Y-%m-%d %H:%M:%S UTC')
printf 'ExecMainExitTimestamp=%s\nExecMainStatus=0\n' "$ts" > "$T/show.txt"; run $NOW
expect "systemd's last successful exit (human-readable timestamp) counts" 0 '^Backup overdue|'
printf 'ExecMainExitTimestamp=%s\nExecMainStatus=3\n' "$ts" > "$T/show.txt"; run $((NOW+1))
expect "a systemd exit status 3 does not count as success" 1 '^Backup overdue|'
# a unit that never ran: status 0 and an EMPTY timestamp must not turn into "today 00:00" (GNU date -d "")
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
printf 'ExecMainStatus=0\nExecMainExitTimestamp=\n' > "$T/show.txt"
REALNOW=$("$REAL_DATE" +%s); touch -d "@$((REALNOW-100*3600))" "$T/restic-env"; run $REALNOW
expect "a never-run unit (empty timestamp) does not hide an overdue backup" 1 '^Backup overdue|'
printf 'ExecMainStatus=0\nExecMainExitTimestamp=n/a\n' > "$T/show.txt"; rm -rf "$T/state"; mkdir -p "$T/state"; rm -f "$T/sent.log"; run $REALNOW
expect "timestamp n/a is ignored too" 1 '^Backup overdue|'
# a partial run's systemd exit time lands just after its stamp: the message must say partial
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
echo $((NOW-90*3600)) > "$T/backup/last-success"; echo $((NOW-40*3600)) > "$T/backup/last-partial"
ts=$("$REAL_DATE" -u -d "@$((NOW-40*3600+5))" '+%a %Y-%m-%d %H:%M:%S UTC')
printf 'ExecMainExitTimestamp=%s\nExecMainStatus=0\n' "$ts" > "$T/show.txt"; run $NOW
expect "an overdue message after a partial run says partial" 1 'Last backup (partial'
if grep -vE '^[[:space:]]*#' "$T/health.sh" | grep -q -- '--timestamp=unix'; then bad "systemctl --timestamp=unix is back (systemd 249 rejects it)"; else ok "no systemctl --timestamp=unix"; fi
# stale backup resolves and a new staleness alerts after the anti-flap window
reset; touch "$T/restic-env" "$T/backup.timer"; touch -d "@$T0" "$T/restic-env"
run $NOW
echo $((NOW+1000)) > "$T/backup/last-success"; run $((NOW+1200))
expect "backup recovery sends Resolved" 1 '^Resolved: backup-stale'
if [[ -f "$T/state/.sent/backup-stale" ]] && (( $(cat "$T/state/.sent/backup-stale") > NOW+1200-6*3600 )); then ok "backup-stale cooldown reset to the 15 min anti-flap"; else bad "backup-stale cooldown not reset"; fi

echo "== SSH login hook: new addresses loud, known ones quiet and at most hourly"
awk '/cat > \/usr\/local\/sbin\/vps-forge-ssh-login <<.EOF./{f=1; next} f&&/^EOF$/{exit} f' "$INSTALLER" \
  | sed -e "s#/etc/vps-forge/notify.env#$T/notify.env#g" \
        -e "s#/var/lib/vps-forge/alerts#$T/state#g" \
        -e "s#/usr/local/bin/vps-notify#$T/bin/vps-notify#g" \
        -e "s#^PATH=.*#PATH='$PATH'#" > "$T/login.sh"   # the host's tools, wherever they live
if [[ ! -s "$T/login.sh" ]] || grep -vE '^[[:space:]]*(#|PATH=)' "$T/login.sh" | grep -nE '(^|[^A-Za-z0-9_$])/(etc|var|usr/local)/'; then
  bad "could not extract the SSH login hook, or it still names a real path"
else
  login() { # user host -> runs the hook and waits for its background sender
    local before; before=$(count '^SSH login')
    PAM_TYPE=open_session PAM_USER=$1 PAM_RHOST=$2 PAM_SERVICE=sshd sh "$T/login.sh" || bad "the hook exited non-zero"
    for _ in $(seq 30); do [[ "$(count '^SSH login')" != "$before" ]] && return; sleep 0.1; done
  }
  reset; printf "SSH_ALERT_IGNORE_IPS='192.0.2.99'\nSSH_ALERT_KNOWN_DAYS=30\n" > "$T/notify.env"
  login admin 192.0.2.10
  expect "the first login from a new address is high priority" 1 '^SSH login: admin|.*new address.*|high$'
  login admin 192.0.2.10
  expect "a repeat within the hour sends nothing" 1 '^SSH login: admin|'
  k="$T/state/ssh-seen/admin@192.0.2.10"
  touch -d '-2 hours' "$k.sent"
  login admin 192.0.2.10
  expect "a known address after an hour is low priority" 1 '^SSH login: admin|.*known address.*|low$'
  login admin 198.51.100.4
  expect "another address is new again" 2 '|high$'
  touch -d '-40 days' "$k.seen" "$k.sent"
  login admin 192.0.2.10
  expect "an address unseen for KNOWN_DAYS is new again" 3 '|high$'
  login deploy 192.0.2.10
  expect "the same address with another user is new" 4 '|high$'
  login admin 192.0.2.99
  expect "SSH_ALERT_IGNORE_IPS sends nothing" 0 '192.0.2.99'
  reset; printf "SSH_ALERT_KNOWN_DAYS=0\n" > "$T/notify.env"
  login admin 192.0.2.10; login admin 192.0.2.10
  expect "SSH_ALERT_KNOWN_DAYS=0 alerts every login at high priority" 2 '|high$'
fi

echo "== installer text"
if grep -q 'TimeoutStartSec=2min' "$INSTALLER"; then ok "the health service has TimeoutStartSec=2min"; else bad "TimeoutStartSec missing from the health service"; fi
if awk '/install -m 600 \/dev\/null "\$CONF"/{a=NR} /cat > "\$CONF" <</{b=NR} END{exit !(a && b && a<b)}' "$INSTALLER"; then ok "notify.env is created mode 600 before it gets content"; else bad "notify.env is written before it is chmod'ed"; fi
# drift: the template heredoc in the installer and assets/alerts/notify.env.example must be identical
awk '/cat > "\$CONF" <<.EOF./{f=1; next} f&&/^EOF$/{exit} f' "$INSTALLER" > "$T/heredoc.env"
if diff -u "$T/heredoc.env" "$SKILL/assets/alerts/notify.env.example" > "$T/drift.diff"; then
  ok "notify.env template: installer heredoc == assets/alerts/notify.env.example"
else
  bad "notify.env template drifted between install-alerts.sh and the example: $(head -n 8 "$T/drift.diff" | tr '\n' '/')"
fi

echo
if (( fail )); then echo "ALERTS TESTS FAILED"; exit 1; fi
echo "ALERTS TESTS PASSED"
