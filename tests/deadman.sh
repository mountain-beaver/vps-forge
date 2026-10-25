#!/usr/bin/env bash
# deadman.sh snapshot/restore round trip in a fake root (VPS_FORGE_ROOT). No services are touched.
# Needs root, or a user namespace: tests/run.sh runs it under `unshare -r` when not root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh
. tests/lib.sh
DEADMAN=$SKILL/scripts/deadman.sh

R=$(mktemp -d); trap 'rm -rf "$R"' EXIT
export VPS_FORGE_ROOT="$R" VPS_FORGE_SKIP_SERVICES=1
mkdir -p "$R/etc/ssh/sshd_config.d" "$R/etc/ufw" "$R/etc/sudoers.d"
echo "PasswordAuthentication yes" > "$R/etc/ssh/sshd_config.d/00-test.conf"
echo "rules-v1" > "$R/etc/ufw/user.rules"
echo "admin ALL=(ALL) ALL" > "$R/etc/sudoers.d/admin"; chmod 440 "$R/etc/sudoers.d/admin"

bash "$DEADMAN" snapshot >/dev/null || { bad "deadman snapshot"; finish; }
[[ -f "$R/var/lib/vps-forge/deadman/latest/snapshot.tar" ]] && ok "snapshot written" || bad "no snapshot.tar"

# A risky change: passwords off, a new drop-in, new firewall rules, a socket override, sudo edited.
echo "PasswordAuthentication no" > "$R/etc/ssh/sshd_config.d/00-test.conf"
echo "broken" > "$R/etc/ssh/sshd_config.d/01-new.conf"
echo "rules-v2" > "$R/etc/ufw/user.rules"
mkdir -p "$R/etc/systemd/system/ssh.socket.d"; echo "[Socket]" > "$R/etc/systemd/system/ssh.socket.d/port.conf"
echo "admin ALL=(ALL) NOPASSWD:ALL" > "$R/etc/sudoers.d/admin"

bash "$DEADMAN" restore >/dev/null || bad "deadman restore exited non-zero"
grep -q yes "$R/etc/ssh/sshd_config.d/00-test.conf" && ok "changed sshd drop-in restored" || bad "sshd drop-in not restored"
[[ ! -e "$R/etc/ssh/sshd_config.d/01-new.conf" ]] && ok "drop-in added after the snapshot removed" || bad "new drop-in survived"
grep -q rules-v1 "$R/etc/ufw/user.rules" && ok "ufw rules restored" || bad "ufw rules not restored"
[[ ! -e "$R/etc/systemd/system/ssh.socket.d" ]] && ok "ssh.socket override created after the snapshot moved aside" || bad "ssh.socket.d survived"
grep -q 'ALL=(ALL) ALL' "$R/etc/sudoers.d/admin" && ok "sudoers restored" || bad "sudoers not restored"
[[ "$(stat -c %a "$R/etc/sudoers.d/admin")" == 440 ]] && ok "sudoers mode 440 kept" || bad "sudoers mode is $(stat -c %a "$R/etc/sudoers.d/admin")"
rb=$(find "$R/var/lib/vps-forge/deadman/latest/" -maxdepth 1 -name 'rolled-back-*' | head -n 1)
[[ -n "$rb" ]] && grep -q 'NOPASSWD' "$rb/etc/sudoers.d/admin" && ok "replaced config kept in $(basename "$rb")" || bad "rolled-back copy missing"

# disarm must tell "changes kept" apart from "already rolled back" (exit 3).
S="$R/var/lib/vps-forge/deadman"
bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm (test mode) failed"
[[ -f "$S/armed-at" ]] && ok "arm writes the armed-at marker" || bad "no armed-at marker after arm"
BU="$R/etc/systemd/system/vps-forge-deadman-boot.service"
[[ -f "$S/armed" && -L "$R/etc/systemd/system/multi-user.target.wants/vps-forge-deadman-boot.service" ]] \
  && grep -qxF "ConditionPathExists=$S/armed" "$BU" && grep -q "^ExecStart=/bin/bash $S/bin/deadman.sh restore --armed $S/20" "$BU" \
  && ! grep -q '^Before=' "$BU" \
  && ok "arm installs the boot-time rollback unit" || bad "boot unit or armed marker missing/wrong after arm"
bash "$DEADMAN" arm 5 >/dev/null 2>&1 && bad "second arm accepted while armed" || ok "second arm refused while armed"
for m in 0 121 x ""; do
  bash "$DEADMAN" extend $m >/dev/null 2>&1 && bad "extend accepted '$m'"
done
snap=$(cat "$S/armed-snapshot")
out=$(bash "$DEADMAN" extend 15 2>&1); rc=$?
[[ $rc == 0 && "$out" == *EXTENDED* && "$(cat "$S/armed-snapshot")" == "$snap" && -f "$S/armed-at" ]] \
  && ok "extend while armed keeps the same snapshot and arm" || bad "extend while armed: rc=$rc out=$out"
out=$(bash "$DEADMAN" disarm 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"changes kept"* ]] && ok "disarm while armed: exit 0, changes kept" || bad "disarm while armed: rc=$rc out=$out"
[[ ! -f "$S/armed-at" ]] && ok "disarm removes the armed-at marker" || bad "armed-at survived disarm"
[[ ! -e "$S/armed" && ! -e "$BU" && ! -L "$R/etc/systemd/system/multi-user.target.wants/vps-forge-deadman-boot.service" ]] \
  && ok "disarm removes the boot unit and its marker" || bad "boot unit or marker survived disarm"

bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "re-arm failed"
echo "PasswordAuthentication no" > "$R/etc/ssh/sshd_config.d/00-test.conf"
bash "$DEADMAN" restore >/dev/null 2>&1 || bad "restore after arm failed"   # what the timer runs
[[ ! -e "$S/armed" && ! -e "$BU" ]] && ok "restore removes the boot unit (no second rollback at boot)" || bad "boot unit survived restore"
out=$(bash "$DEADMAN" disarm 2>&1); rc=$?
[[ $rc == 3 && "$out" == *"ROLLED BACK"* ]] && ok "disarm after the rollback fired: exit 3, ROLLED BACK" || bad "disarm after rollback: rc=$rc out=$out"
out=$(bash "$DEADMAN" disarm 2>&1); rc=$?
[[ $rc == 3 ]] && ok "disarm keeps reporting the rollback until the next arm" || bad "second disarm after rollback: rc=$rc"
out=$(bash "$DEADMAN" extend 10 2>&1); rc=$?
[[ $rc == 3 && "$out" == *"ROLLED BACK"* ]] && ok "extend after the rollback fired: exit 3, ROLLED BACK" || bad "extend after rollback: rc=$rc out=$out"
out=$(bash "$DEADMAN" status 2>&1)
[[ "$out" == *"ROLLED BACK since the last arm"* ]] && ok "status shows the rollback" || bad "status does not show the rollback"
echo 1 > "$S/restored-at"   # boot-time restore with the clock far behind (before NTP sync)
bash "$DEADMAN" disarm >/dev/null 2>&1; [[ $? == 3 ]] && ok "disarm reports the rollback even with clock skew" || bad "clock skew hides the rollback"
bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm after a rollback failed"
bash "$DEADMAN" disarm >/dev/null 2>&1 && ok "a new arm clears the old rollback" || bad "disarm after a fresh arm failed"
out=$(bash "$DEADMAN" disarm 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"not armed"* ]] && ok "disarm when not armed: exit 0" || bad "disarm not armed: rc=$rc out=$out"
bash "$DEADMAN" extend 10 >/dev/null 2>&1 && bad "extend accepted while not armed" || ok "extend refused while not armed"

# fail2ban: the client address is recorded at arm (validated) and read back by restore.
bash "$DEADMAN" arm 5 --ip '1.2.3.4;id' >/dev/null 2>&1 && bad "arm accepted a bogus --ip" || ok "arm rejects a bogus --ip"
[[ ! -f "$S/armed-at" ]] && ok "a rejected arm leaves nothing armed" || bad "rejected arm left armed-at behind"
bash "$DEADMAN" arm 5 --ip 203.0.113.7 >/dev/null 2>&1 || bad "arm --ip failed"
[[ "$(cat "$S/latest/unban-ip" 2>/dev/null)" == 203.0.113.7 ]] && ok "arm --ip records the address" || bad "unban-ip not recorded"
out=$(bash "$DEADMAN" restore 2>&1)
[[ "$out" == *"unban skipped for: 203.0.113.7"* ]] && ok "restore picks up the recorded address" || bad "restore did not read unban-ip: $out"
bash "$DEADMAN" disarm >/dev/null 2>&1; [[ $? == 3 ]] || bad "disarm after the --ip rollback did not exit 3"
SSH_CLIENT="198.51.100.9 50000 22" bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm with SSH_CLIENT failed"
[[ "$(cat "$S/latest/unban-ip" 2>/dev/null)" == 198.51.100.9 ]] && ok "arm takes the address from SSH_CLIENT" || bad "SSH_CLIENT address not recorded"
bash "$DEADMAN" disarm >/dev/null 2>&1 || bad "final disarm failed"

# A restore that cannot move the current config aside must say so and exit non-zero, not
# drop the snapshot copy inside the old directory and report "restored". A regular file
# where the rolled-back-<ts> directory goes makes the move aside fail; a date shim pins <ts>.
bash "$DEADMAN" snapshot >/dev/null || bad "snapshot before the failing restore"
echo "PasswordAuthentication maybe" > "$R/etc/ssh/sshd_config.d/00-test.conf"
shim=$(mktemp -d); real_date=$(command -v date)
printf '#!/bin/sh\n[ "$1" = "+%%Y%%m%%d-%%H%%M%%S" ] && { echo 20000101-000000; exit 0; }\nexec %s "$@"\n' "$real_date" > "$shim/date"
chmod +x "$shim/date"
: > "$S/latest/rolled-back-20000101-000000"
out=$(PATH="$shim:$PATH" bash "$DEADMAN" restore 2>&1); rc=$?
rm -rf "$shim"
[[ $rc != 0 && "$out" == *"NOT restored"* ]] && ok "restore reports a failed swap and exits non-zero" || bad "failed swap: rc=$rc out=$out"
grep -qx 'deadman: restored /etc/ssh' <<<"$out" && bad "a failed swap was logged as restored" || ok "a failed swap is not logged as restored"
[[ ! -e "$R/etc/ssh/ssh.vps-forge-new" && ! -e "$R/etc/ssh.vps-forge-new" ]] && grep -q maybe "$R/etc/ssh/sshd_config.d/00-test.conf" \
  && ok "a failed swap leaves the current config in place, nothing nested" || bad "failed swap left a nested or half-swapped /etc/ssh"
out=$(bash "$DEADMAN" status 2>&1)
[[ "$out" == *"PARTIAL: NOT restored: /etc/ssh"* ]] && ok "status reports the partial rollback" || bad "status hides the partial rollback: $out"
bash "$DEADMAN" arm 5 >/dev/null 2>&1 && [[ ! -e "$S/restore-partial" ]] && ok "a new arm clears the partial marker" || bad "partial marker survived arm"
bash "$DEADMAN" disarm >/dev/null 2>&1 || bad "disarm after the partial-rollback test failed"


# Paths absent at arm and created in the window must not survive the rollback (a new
# /etc/nftables.conf with a drop policy, an iptables rules dir, a mask symlink on ssh.service).
bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm before the absent-path test failed"
A=$(cat "$S/armed-snapshot" 2>/dev/null)
grep -qxF etc/nftables.conf "$A/absent" 2>/dev/null && ok "arm records the paths that do not exist yet" || bad "absent list missing etc/nftables.conf"
echo 'table inet vfdrop { chain input { type filter hook input priority 0; policy drop; } }' > "$R/etc/nftables.conf"
mkdir -p "$R/etc/iptables"; echo '*filter' > "$R/etc/iptables/rules.v4"
mkdir -p "$R/etc/systemd/system"; ln -s /dev/null "$R/etc/systemd/system/ssh.service"
echo "x ALL=(ALL) NOPASSWD:ALL" > "$R/etc/sudoers.d/x"
bash "$DEADMAN" restore >/dev/null 2>&1 || bad "restore in the absent-path test failed"
[[ ! -e "$R/etc/nftables.conf" && ! -e "$R/etc/iptables" && ! -L "$R/etc/systemd/system/ssh.service" && ! -e "$R/etc/sudoers.d/x" ]] \
  && ok "files created after arm are removed by the rollback" || bad "a file created after arm survived the rollback"
rb=$(find "$A" -maxdepth 1 -name 'rolled-back-*' | head -n 1)
[[ -n "$rb" && -f "$rb/etc/nftables.conf" && -L "$rb/etc/systemd/system/ssh.service" ]] \
  && ok "removed files are kept in the rolled-back dir" || bad "removed files not kept in $rb"
bash "$DEADMAN" disarm >/dev/null 2>&1; [[ $? == 3 ]] || bad "disarm after the absent-path rollback did not exit 3"

# A snapshot from before the absent list must not remove paths that a newer PATHS added.
bash "$DEADMAN" snapshot >/dev/null 2>&1 || bad "snapshot for the old-format test failed"
rm -f "$S/latest/absent"
mkdir -p "$R/etc/pam.d"; echo "auth required pam_unix.so" > "$R/etc/pam.d/common-auth"
bash "$DEADMAN" restore "$(readlink -f "$S/latest")" >/dev/null 2>&1
[[ -f "$R/etc/pam.d/common-auth" ]] && ok "an old-format snapshot leaves newly listed paths alone" || bad "old-format snapshot removed /etc/pam.d/common-auth"

# Snapshots taken in the same second get distinct dirs; rotation keeps the armed snapshot, and
# restore without DIR rolls back to it rather than to the newest snapshot.
shim=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = "+%%Y%%m%%d-%%H%%M%%S" ] && { echo 20300101-000000; exit 0; }\nexec %s "$@"\n' "$real_date" > "$shim/date"
chmod +x "$shim/date"
echo "PasswordAuthentication yes" > "$R/etc/ssh/sshd_config.d/00-test.conf"
PATH="$shim:$PATH" bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm with a pinned clock failed"
A=$(cat "$S/armed-snapshot" 2>/dev/null)
echo "PasswordAuthentication no" > "$R/etc/ssh/sshd_config.d/00-test.conf"
PATH="$shim:$PATH" bash "$DEADMAN" snapshot >/dev/null 2>&1 || bad "same-second snapshot failed"
[[ -n "$A" && "$(readlink -f "$S/latest")" != "$A" ]] && tar -tf "$A/snapshot.tar" >/dev/null 2>&1 \
  && ok "a snapshot in the same second gets its own dir" || bad "same-second snapshot overwrote the armed one"
for _ in $(seq 12); do bash "$DEADMAN" snapshot >/dev/null 2>&1; done
rm -rf "$shim"
[[ -d "$A" ]] && ok "rotation keeps the armed snapshot" || bad "rotation deleted the armed snapshot"
[[ $(find "$S" -mindepth 1 -maxdepth 1 -type d -name '20*' | wc -l) -le 11 ]] && ok "rotation still prunes old snapshots" || bad "rotation pruned nothing"
bash "$DEADMAN" restore >/dev/null 2>&1 || bad "restore without DIR while armed failed"
grep -q yes "$R/etc/ssh/sshd_config.d/00-test.conf" && ok "restore without DIR uses the armed snapshot" || bad "restore without DIR used the latest snapshot"
bash "$DEADMAN" disarm >/dev/null 2>&1

# The timer and the boot unit run 'restore --armed DIR': it acts only while DIR is the armed snapshot.
bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm before the identity test failed"
A=$(cat "$S/armed-snapshot" 2>/dev/null)
echo "PasswordAuthentication no" > "$R/etc/ssh/sshd_config.d/00-test.conf"
bash "$DEADMAN" restore --armed "$S/20000101-000000-old" >/dev/null 2>&1 || bad "stale restore --armed exited non-zero"
grep -q no "$R/etc/ssh/sshd_config.d/00-test.conf" && [[ -f "$S/armed" && "$(cat "$S/armed-snapshot")" == "$A" ]] \
  && ok "a restore for another arm's snapshot changes nothing" || bad "a stale restore --armed touched the current arm"
bash "$DEADMAN" disarm >/dev/null 2>&1 || bad "disarm in the identity test failed"
bash "$DEADMAN" restore --armed "$A" >/dev/null 2>&1
grep -q no "$R/etc/ssh/sshd_config.d/00-test.conf" && [[ ! -f "$S/restored-at" ]] \
  && ok "the timer's restore after a disarm changes nothing" || bad "restore --armed ran after disarm"
bash "$DEADMAN" arm 5 >/dev/null 2>&1 || bad "arm before restore --armed failed"
A=$(cat "$S/armed-snapshot" 2>/dev/null)
echo "PasswordAuthentication maybe" > "$R/etc/ssh/sshd_config.d/00-test.conf"
bash "$DEADMAN" restore --armed "$A" >/dev/null 2>&1 || bad "restore --armed for the armed snapshot failed"
grep -q no "$R/etc/ssh/sshd_config.d/00-test.conf" && [[ ! -e "$S/armed-snapshot" ]] \
  && ok "restore --armed rolls back the armed snapshot and ends the arm" || bad "restore --armed did not roll back"
bash "$DEADMAN" disarm >/dev/null 2>&1

# A boot-time rollback still pending (the reboot protection marker of an older arm) blocks arm.
echo "$A" > "$S/armed"
out=$(bash "$DEADMAN" arm 5 2>&1); rc=$?
[[ $rc != 0 && "$out" == *"has not run yet"* ]] && ok "arm refused while a boot-time rollback is pending" || bad "arm with a pending boot rollback: rc=$rc out=$out"
rm -f "$S/armed"

# client-ip: also from a parent process, which is how it works under sudo (sudo drops SSH_CLIENT).
out=$(SSH_CLIENT="198.51.100.9 50000 22" bash "$DEADMAN" client-ip 2>&1)
[[ "$out" == 198.51.100.9 ]] && ok "client-ip prints SSH_CLIENT's address" || bad "client-ip: $out"
out=$(SSH_CONNECTION="2001:db8::5 50000 2001:db8::1 22" bash -c 'env -u SSH_CLIENT -u SSH_CONNECTION bash "$1" client-ip; :' _ "$DEADMAN" 2>&1)
[[ "$out" == 2001:db8::5 ]] && ok "client-ip finds the address in a parent process" || bad "client-ip via parent: $out"
out=$(SSH_CLIENT="999.1.1.1 50000 22" bash "$DEADMAN" client-ip 2>/dev/null); rc=$?
[[ $rc == 1 && -z "$out" ]] && ok "client-ip rejects an address that is not an IP literal" || bad "client-ip printed '$out' rc=$rc"
if [[ -z "${SSH_CLIENT:-}${SSH_CONNECTION:-}" ]]; then
  out=$(bash "$DEADMAN" client-ip 2>&1); rc=$?
  [[ $rc == 1 && "$out" == *"no SSH client"* ]] && ok "client-ip outside SSH: exit 1 with a message" || bad "client-ip outside SSH: rc=$rc out=$out"
else
  note "client-ip outside SSH (this test runs under SSH)"
fi
for v in ::1 ::ffff:192.0.2.1 2001:db8::1; do
  bash "$DEADMAN" arm 5 --ip "$v" >/dev/null 2>&1 && bash "$DEADMAN" disarm >/dev/null 2>&1 || bad "arm --ip $v rejected"
done
for v in 1.2.3.256 1:2 2001:db8:::1 12345::1 1.2.3; do
  bash "$DEADMAN" arm 5 --ip "$v" >/dev/null 2>&1 && { bad "arm --ip $v accepted"; bash "$DEADMAN" disarm >/dev/null 2>&1; }
done
ok "--ip accepts IPv4/IPv6 literals only"

finish
