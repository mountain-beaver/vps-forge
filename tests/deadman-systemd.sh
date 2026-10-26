#!/usr/bin/env bash
# deadman.sh with real systemd: timer rollback, enable states, files created after arm, nft
# tables, extend, the boot-time rollback after a reboot, locking, client-ip under sudo over SSH,
# and ufw and fail2ban (enable undone, deleted rule reloaded, ban lifted).
# Runs in a throwaway podman container (localhost/u24sd: Ubuntu 24.04 booting systemd) and takes
# about six minutes. Needs network access for apt.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh
. tests/lib.sh
IMAGE=${VPS_FORGE_SYSTEMD_IMAGE:-localhost/u24sd}

if ! systemd_image "$IMAGE"; then
  note "deadman-systemd needs podman (it runs Ubuntu 24.04 with systemd as PID 1 in a container)"
  exit 0
fi

C=vf-deadman-$$
trap 'podman rm -f -t 0 "$C" >/dev/null 2>&1' EXIT
x() { podman exec "$C" bash -c "$1"; }
q() { podman exec "$C" bash -c "$1" >/dev/null 2>&1; }
booted() { # wait until systemd accepts commands
  local i
  for ((i = 0; i < 60; i++)); do
    [[ "$(podman exec "$C" systemctl is-system-running 2>/dev/null)" =~ ^(running|degraded|starting)$ ]] && return 0
    sleep 1
  done
  return 1
}
wait_rolled_back() { # seconds
  local i
  for ((i = 0; i < $1; i += 3)); do
    # ROLLED BACK shows as soon as the restore starts; wait for the unit to finish, too
    [[ "$(x 'vps-forge-deadman status' 2>/dev/null)" == *$'\nROLLED BACK'* ]] \
      && ! q 'systemctl is-active --quiet vps-forge-deadman.service vps-forge-deadman-boot.service' && return 0
    sleep 3
  done
  return 1
}

step "start $IMAGE"
# SYS_PTRACE: root on a real server has it, and client-ip needs it to read sudo's environment.
podman run -d --name "$C" --systemd=always --cap-add NET_ADMIN --cap-add SYS_PTRACE -v "$PWD:/src:ro" "$IMAGE" >/dev/null || { bad "podman run"; finish; }
booted || { bad "systemd did not come up"; finish; }
x 'apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends sudo nftables openssh-client >/dev/null 2>&1' \
  || { bad "apt-get install sudo nftables openssh-client"; finish; }
x 'install -m 755 /src/skills/vps-forge/scripts/deadman.sh /usr/local/sbin/vps-forge-deadman' || bad "install deadman"
# The reproduced case: no /etc/nftables.conf at arm, nftables.service disabled and inactive.
# "keepme" stands in for the tables that ufw/fail2ban/docker own: it must survive every rollback.
x 'rm -f /etc/nftables.conf; systemctl disable --now nftables >/dev/null 2>&1; nft add table inet keepme' || bad "nft setup"
x 'useradd -m -s /bin/bash tester && usermod -p "*" tester && echo "tester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tester \
   && chmod 440 /etc/sudoers.d/tester && ssh-keygen -q -t ed25519 -N "" -f /root/k \
   && install -d -m 700 -o tester -g tester ~tester/.ssh && install -m 600 -o tester -g tester /root/k.pub ~tester/.ssh/authorized_keys' \
  || bad "test user setup"
SSH='ssh -i /root/k -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 tester@127.0.0.1'

step "client-ip under sudo in an SSH session"
out=$(x "$SSH 'sudo -n vps-forge-deadman client-ip'" 2>&1)
[[ "$out" == 127.0.0.1 ]] && ok "sudo vps-forge-deadman client-ip over SSH prints 127.0.0.1" || bad "client-ip over SSH: $out"
out=$(x "$SSH -tt 'sudo -n vps-forge-deadman client-ip'" 2>&1 | tr -d '\r')
[[ "$out" == 127.0.0.1 ]] && ok "the same with a tty (sudo's use_pty monitor in the chain)" || bad "client-ip over SSH with a tty: $out"
out=$(x 'vps-forge-deadman client-ip' 2>&1); rc=$?
[[ $rc == 1 && "$out" == *"no SSH client"* ]] && ok "client-ip outside SSH: exit 1" || bad "client-ip outside SSH: rc=$rc out=$out"

step "timer rollback: broken sshd, disabled ssh units, files created after arm"
x 'vps-forge-deadman arm 1' >/dev/null || bad "arm 1"
x 'echo "BogusDirective yes" > /etc/ssh/sshd_config.d/99-broken.conf
   systemctl disable ssh.service ssh.socket >/dev/null 2>&1
   echo "intruder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/x && chmod 440 /etc/sudoers.d/x
   mkdir -p /etc/iptables && echo "*filter" > /etc/iptables/rules.v4
   printf "table inet vfdrop {\n  chain input { type filter hook input priority 0; policy drop; }\n}\n" > /etc/nftables.conf
   systemctl enable --now nftables >/dev/null 2>&1
   nft add table inet f2b-table' || bad "the risky change"
q "$SSH true" && bad "the drop policy did not take effect (test is not meaningful)" || ok "the change locked SSH out"
wait_rolled_back 150 && ok "the timer rolled back" || bad "no rollback within 150 s: $(x 'vps-forge-deadman status; journalctl -t vps-forge-deadman --no-pager | tail -n 20' 2>&1)"
q '! test -e /etc/ssh/sshd_config.d/99-broken.conf && sshd -t' && ok "sshd config restored" || bad "sshd config not restored"
for u in ssh.service ssh.socket; do
  st=$(x "systemctl is-enabled $u" 2>&1)
  [[ "$st" == enabled ]] && ok "$u enabled again" || bad "$u is $st after the rollback"
done
st=$(x 'systemctl is-enabled nftables; systemctl is-active nftables' 2>&1 | paste -sd' ')
[[ "$st" == "disabled inactive" ]] && ok "nftables.service disabled and stopped again" || bad "nftables.service is $st after the rollback"
q 'test ! -e /run/systemd/system/nftables.service.d/zz-vps-forge-deadman.conf' || bad "the no-flush drop-in was left behind"
q 'test ! -e /etc/nftables.conf && test ! -e /etc/sudoers.d/x && test ! -e /etc/iptables' \
  && ok "files created after arm are gone" || bad "files created after arm survived: $(x 'ls -d /etc/nftables.conf /etc/sudoers.d/x /etc/iptables 2>/dev/null')"
tables=$(x 'nft list tables' 2>&1)
[[ "$tables" != *vfdrop* ]] && ok "the table from the rolled-back nftables.conf is deleted" || bad "vfdrop survived: $tables"
[[ "$tables" == *"inet keepme"* && "$tables" == *"inet f2b-table"* ]] \
  && ok "tables not declared in rolled-back config are kept" || bad "a foreign table was deleted: $tables"
q "$SSH true" && ok "a new SSH login works after the rollback" || bad "SSH login fails after the rollback"
x 'vps-forge-deadman disarm' >/dev/null 2>&1; rc=$?
[[ $rc == 3 ]] && ok "disarm after the rollback exits 3" || bad "disarm after the rollback: rc=$rc"

step "two concurrent arms"
podman exec "$C" vps-forge-deadman arm 5 >/dev/null 2>&1 & p1=$!
podman exec "$C" vps-forge-deadman arm 5 >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
[[ $(( (r1 == 0) + (r2 == 0) )) == 1 ]] \
  && ok "exactly one of two concurrent arms succeeds ($r1, $r2)" || bad "concurrent arms: rc $r1 and $r2"
q 'test $(ls -d /var/lib/vps-forge/deadman/20* | wc -l) -ge 1 && systemctl is-active --quiet vps-forge-deadman.timer' \
  || bad "no timer after the concurrent arms"
x 'vps-forge-deadman disarm' >/dev/null 2>&1 && ok "disarm" || bad "disarm after the concurrent arms"

step "extend moves the rollback and keeps the snapshot"
x 'vps-forge-deadman arm 1' >/dev/null 2>&1 || bad "arm 1"
snap=$(x 'cat /var/lib/vps-forge/deadman/armed-snapshot' 2>&1)
x 'echo "MaxAuthTries 5" > /etc/ssh/sshd_config.d/40-slow.conf' || bad "change"
x 'vps-forge-deadman extend 3' >/dev/null 2>&1 && ok "extend 3 while armed" || bad "extend 3: $(x 'vps-forge-deadman extend 3' 2>&1)"
sleep 75   # past the original 1-minute rollback
st=$(x 'vps-forge-deadman status' 2>&1)
[[ "$st" == ARMED* && "$st" != *"ROLLED BACK"* ]] && q 'test -e /etc/ssh/sshd_config.d/40-slow.conf' \
  && ok "no rollback at the original time" || bad "rolled back despite extend: $st"
[[ "$(x 'cat /var/lib/vps-forge/deadman/armed-snapshot' 2>&1)" == "$snap" ]] && ok "the same snapshot is armed" || bad "extend changed the armed snapshot"
x 'vps-forge-deadman disarm' >/dev/null 2>&1 && ok "disarm after extend keeps the change" || bad "disarm after extend"
x 'rm -f /etc/ssh/sshd_config.d/40-slow.conf'

step "reboot while armed: the boot-time rollback"
x 'vps-forge-deadman arm 5' >/dev/null 2>&1 || bad "arm 5"
x 'echo "MaxAuthTries 4" > /etc/ssh/sshd_config.d/50-change.conf' || bad "change"
# Hold the boot rollback for a while so the arm below provably races a pending rollback.
x 'mkdir -p /etc/systemd/system/vps-forge-deadman-boot.service.d &&
   printf "[Service]\nExecStartPre=/bin/sleep 15\n" > /etc/systemd/system/vps-forge-deadman-boot.service.d/test-delay.conf' || bad "delay drop-in"
podman restart -t 10 "$C" >/dev/null || bad "podman restart"
out=$(podman exec "$C" vps-forge-deadman arm 5 2>&1); rc=$?
[[ $rc != 0 && ( "$out" == *"has not run yet"* || "$out" == *"rollback is running"* ) ]] \
  && ok "arm refused while the boot-time rollback is pending" || bad "arm during a pending boot rollback: rc=$rc out=$out"
booted || bad "systemd did not come back after the restart"
wait_rolled_back 90 && ok "the boot unit rolled back" || bad "no boot rollback within 90 s: $(x 'systemctl status vps-forge-deadman-boot.service --no-pager' 2>&1 | tail -n 15)"
q 'test ! -e /etc/ssh/sshd_config.d/50-change.conf' && ok "the change from before the reboot is reverted" || bad "50-change.conf survived the boot rollback"
x 'rm -rf /etc/systemd/system/vps-forge-deadman-boot.service.d && systemctl daemon-reload'
q 'vps-forge-deadman arm 5 && vps-forge-deadman disarm' && ok "arm and disarm work after the boot rollback" || bad "arm/disarm after the boot rollback"
q '! test -e /var/lib/vps-forge/deadman/armed && ! test -e /etc/systemd/system/vps-forge-deadman-boot.service' \
  && ok "no reboot protection left behind" || bad "boot unit or marker left behind"

# Installed only now, so the steps above run without ufw and fail2ban. The checks read the live
# state (ufw status, iptables, fail2ban's ban list): restored files alone don't prove a reload.
# ufw always accepts loopback, so these don't try to lock SSH out.
step "ufw and fail2ban: enable rolled back, deleted rule and ban undone"
x 'apt-get install -y -qq --no-install-recommends ufw fail2ban python3-systemd >/dev/null 2>&1' || bad "apt-get install ufw fail2ban"
x 'printf "[sshd]\nenabled = true\nbackend = systemd\n" > /etc/fail2ban/jail.d/zz-test.local && systemctl restart fail2ban' || bad "fail2ban setup"
f2b_up() { local i; for ((i = 0; i < 20; i++)); do q 'fail2ban-client status sshd' && return 0; sleep 1; done; return 1; }
f2b_up || bad "fail2ban's sshd jail did not start: $(x 'systemctl status fail2ban --no-pager; journalctl -u fail2ban -n 20 --no-pager' 2>&1 | tail -n 25)"
q 'ufw status | grep -q "^Status: inactive"' || bad "ufw is active before the test"

x 'vps-forge-deadman arm 1' >/dev/null 2>&1 || bad "arm 1"
x 'ufw default deny incoming >/dev/null && ufw --force enable >/dev/null' || bad "ufw enable"
q 'ufw status | grep -q "^Status: active"' || bad "ufw did not come up (test is not meaningful)"
wait_rolled_back 150 && ok "the timer rolled back" || bad "no rollback within 150 s: $(x 'journalctl -t vps-forge-deadman --no-pager | tail -n 20' 2>&1)"
q 'ufw status | grep -q "^Status: inactive"' && ok "ufw enabled during the window is inactive again" || bad "ufw after the rollback: $(x 'ufw status' 2>&1)"
st=$(x 'systemctl is-enabled ufw.service' 2>&1)
x 'grep -q "^ENABLED=no" /etc/ufw/ufw.conf' && ok "ufw.conf says ENABLED=no again (ufw.service is $st)" || bad "ufw.conf: $(x 'grep ENABLED /etc/ufw/ufw.conf' 2>&1)"

x 'ufw allow 22/tcp >/dev/null && ufw --force enable >/dev/null' || bad "ufw allow 22/tcp + enable"
q 'iptables -S ufw-user-input | grep -q -- "--dport 22 "' || bad "the SSH rule is not loaded (test is not meaningful)"
# 192.0.2.7 (TEST-NET-1): not in fail2ban's default ignoreip, unlike 127.0.0.1
x 'vps-forge-deadman arm 1 --ip 192.0.2.7' >/dev/null 2>&1 || bad "arm 1 --ip 192.0.2.7"
x 'ufw --force delete allow 22/tcp >/dev/null && fail2ban-client set sshd banip 192.0.2.7 >/dev/null' || bad "delete the SSH rule + ban"
q 'iptables -S ufw-user-input | grep -q -- "--dport 22 "' && bad "the SSH rule is still loaded (test is not meaningful)"
[[ "$(x 'fail2ban-client banned' 2>&1)" == *192.0.2.7* ]] || bad "the ban did not take (test is not meaningful)"
wait_rolled_back 150 && ok "the timer rolled back" || bad "no rollback within 150 s: $(x 'journalctl -t vps-forge-deadman --no-pager | tail -n 20' 2>&1)"
q 'ufw status | grep -q "^Status: active"' && ok "ufw is still active" || bad "ufw after the rollback: $(x 'ufw status' 2>&1)"
q 'iptables -S ufw-user-input | grep -q -- "--dport 22 "' && ok "the deleted SSH rule is loaded again" || bad "SSH rule after the rollback: $(x 'iptables -S ufw-user-input' 2>&1)"
f2b_up && ok "fail2ban is running" || bad "fail2ban is down after the rollback"
out=$(x 'fail2ban-client banned' 2>&1)
[[ "$out" != *192.0.2.7* ]] && ok "the address recorded at arm is unbanned" || bad "192.0.2.7 is still banned: $out"
x 'journalctl -t vps-forge-deadman --no-pager | grep -q "unbanned 192.0.2.7"' && ok "the unban is logged" || bad "no unban in the journal"
x 'ufw --force disable >/dev/null; ufw --force reset >/dev/null'

finish
