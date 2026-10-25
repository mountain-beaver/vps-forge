#!/usr/bin/env bash
# audit.sh checks that need systemd as PID 1 and NET_ADMIN: timers, units enabled at boot,
# ssh.socket ports, a real fail2ban jail, nftables/iptables per address family.
#
#   tests/audit-systemd.sh          # on the host: starts an Ubuntu 24.04 systemd container
#                                   # with podman and runs itself inside (--inside)
#
# Uses localhost/u24sd (or VPS_FORGE_SYSTEMD_IMAGE) and builds it when it's missing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh
. tests/lib.sh

if [[ "${1:-}" != --inside ]]; then
  IMAGE=${VPS_FORGE_SYSTEMD_IMAGE:-localhost/u24sd}
  systemd_image "$IMAGE" || { echo "need podman (docker can't run systemd as PID 1 here)" >&2; exit 2; }
  NAME=vps-forge-audit-sd-$$
  trap 'podman rm -f "$NAME" >/dev/null 2>&1' EXIT
  # all/default redirects off: only the interface value is left to catch
  podman run -d --name "$NAME" --systemd=always --cap-add NET_ADMIN \
    --sysctl net.ipv6.conf.all.accept_redirects=0 --sysctl net.ipv6.conf.default.accept_redirects=0 \
    -e VPS_FORGE_DISPOSABLE=1 -v "$PWD:/src:ro" -w /src "$IMAGE" >/dev/null || exit 2
  podman exec "$NAME" timeout 90 systemctl is-system-running --wait >/dev/null 2>&1 || true
  podman exec -e VPS_FORGE_DISPOSABLE=1 -w /src "$NAME" bash tests/audit-systemd.sh --inside
  exit
fi

require_disposable_container
AUDIT=$SKILL/scripts/audit.sh
echo "audit systemd scenarios on $(. /etc/os-release; echo "$PRETTY_NAME")"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt_install python3 nftables iptables fail2ban python3-systemd unattended-upgrades ufw
# fail2ban's packaged sshd jail reads /var/log/auth.log, which doesn't exist here
rm -f /etc/fail2ban/jail.d/defaults-debian.conf

expect() { # scenario check-id STATUS...  (any of the listed statuses passes)
  local scen=$1 id=$2; shift 2
  local got want
  got=$(python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); i=sys.argv[2]
print(",".join(c["status"] for c in d["checks"] if c["id"]==i) or "absent")' "$OUT" "$id")
  for want in "$@"; do
    if [[ ",$got," == *",$want,"* ]]; then ok "$scen: $id = $want"; return; fi
  done
  bad "$scen: $id = $got, want $*"
}
msg_has() { # scenario check-id regex description
  python3 -I -c 'import json,re,sys
m=[c["message"] for c in json.load(open(sys.argv[1]))["checks"] if c["id"]==sys.argv[2]]
sys.exit(0 if m and re.search(sys.argv[3], m[0]) else 1)' "$OUT" "$2" "$3" && ok "$1: $4" || bad "$1: $2 not: $4"
}
run_audit() { # scenario
  OUT=$(mktemp)
  bash "$AUDIT" --json > "$OUT"
  python3 -I -m json.tool "$OUT" >/dev/null || bad "$1: audit.sh --json is not valid JSON"
}

step "backups.job: only enabled, scheduled timers count"
run_audit timers-stock
expect timers-stock backups.job WARN # dpkg-db-backup.timer is active on every Debian/Ubuntu
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' > /etc/systemd/system/restic-backup.service
printf '[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/restic-backup.timer
systemctl daemon-reload
systemctl start restic-backup.timer
run_audit timer-started-only
expect timer-started-only backups.job WARN
systemctl enable restic-backup.timer 2>/dev/null
run_audit timer-enabled
expect timer-enabled backups.job PASS
systemctl disable --now restic-backup.timer 2>/dev/null; systemctl mask restic-backup.timer 2>/dev/null
run_audit timer-masked
expect timer-masked backups.job WARN
systemctl unmask restic-backup.timer 2>/dev/null
rm -f /etc/systemd/system/restic-backup.*; systemctl daemon-reload

step "updates.unattended: the apt timers must run"
run_audit uu-stock
expect uu-stock updates.unattended PASS
systemctl mask apt-daily.timer 2>/dev/null
run_audit uu-masked
expect uu-masked updates.unattended FAIL
systemctl unmask apt-daily.timer 2>/dev/null
systemctl disable apt-daily-upgrade.timer 2>/dev/null
run_audit uu-disabled
expect uu-disabled updates.unattended FAIL
systemctl enable apt-daily-upgrade.timer 2>/dev/null

step "ssh.boot: SSH must come back after a reboot"
run_audit ssh-enabled
expect ssh-enabled ssh.boot PASS
systemctl disable ssh.service ssh.socket 2>/dev/null
run_audit ssh-disabled
expect ssh-disabled ssh.boot FAIL
systemctl enable ssh.service ssh.socket 2>/dev/null

step "ssh.socket on 2222, fail2ban jail on port ssh"
printf '[sshd]\nenabled = true\nbackend = systemd\nport = ssh\nignoreip = 127.0.0.1/8 ::1\n' > /etc/fail2ban/jail.d/zz-test.local
systemctl restart fail2ban; sleep 2
mkdir -p /etc/systemd/system/ssh.socket.d
printf '[Socket]\nListenStream=\nListenStream=2222\n' > /etc/systemd/system/ssh.socket.d/override.conf
systemctl daemon-reload; systemctl stop ssh.service 2>/dev/null; systemctl restart ssh.socket; systemctl start ssh.service
run_audit socket-2222
expect socket-2222 intrusion.ips WARN
msg_has socket-2222 ssh.port '2222' "ssh.port shows the socket port"
expect socket-2222 intrusion.ignoreip WARN
sed -i 's/^port = ssh/port = 2222/; s/^ignoreip = .*/ignoreip = 127.0.0.1\/8 ::1 198.51.100.7/' /etc/fail2ban/jail.d/zz-test.local
systemctl restart fail2ban; sleep 2
run_audit socket-jail-2222
expect socket-jail-2222 intrusion.ips PASS
msg_has socket-jail-2222 intrusion.ips 'total failed: [0-9]+' "PASS shows the failed count"
expect socket-jail-2222 intrusion.ignoreip absent
systemctl stop ssh.service 2>/dev/null # only the socket listens now
run_audit socket-idle
python3 -I -c 'import json,sys
m=[c for c in json.load(open(sys.argv[1]))["checks"] if c["id"]=="exposure.listen" and "/2222 " in c["message"]]
sys.exit(0 if m and all(c["status"]=="INFO" and "127.0.0.1" not in c["message"] for c in m) else 1)' "$OUT" \
  && ok "socket-idle: no 'bind to 127.0.0.1' advice for ssh.socket" || bad "socket-idle: ssh.socket listener flagged"
rm -rf /etc/systemd/system/ssh.socket.d /etc/fail2ban/jail.d/zz-test.local
systemctl daemon-reload; systemctl restart ssh.socket; systemctl start ssh.service; systemctl stop fail2ban

step "firewall: per address family, and restored at boot"
# A public IPv6 address, whatever the container network provides.
IFACE=$(ip -4 route show default | awk '{print $5; exit}')
ip -6 addr add 2001:db8:1::5/64 dev "$IFACE" 2>/dev/null
nft flush ruleset
printf 'table ip f {\n\tchain input {\n\t\ttype filter hook input priority 0; policy drop;\n\t\ttcp dport 22 accept\n\t}\n}\n' | nft -f -
run_audit nft-ip-only
expect nft-ip-only firewall.host PASS
expect nft-ip-only firewall.ipv6 FAIL
expect nft-ip-only firewall.boot WARN
systemctl enable nftables 2>/dev/null
run_audit nft-enabled
expect nft-enabled firewall.boot PASS
systemctl disable nftables 2>/dev/null
nft flush ruleset
printf 'table inet f {\n\tchain input {\n\t\ttype filter hook input priority 0; policy accept;\n\t\ttcp dport 22 accept\n\t\tcounter reject with icmpx type admin-prohibited\n\t}\n}\n' | nft -f -
run_audit nft-inet-final-reject
expect nft-inet-final-reject firewall.host PASS
expect nft-inet-final-reject firewall.ipv6 PASS
nft flush ruleset
# Oracle Cloud style: policy ACCEPT, then a final REJECT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited
run_audit oci-ip6-open
expect oci-ip6-open firewall.host PASS
expect oci-ip6-open firewall.ipv6 FAIL
expect oci-ip6-open firewall.boot WARN
msg_has oci-ip6-open firewall.boot 'iptables' "names the iptables rules"
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -j DROP
run_audit oci-ip6-closed
expect oci-ip6-closed firewall.ipv6 PASS
nft flush ruleset
ufw allow 22/tcp >/dev/null; ufw --force enable >/dev/null
run_audit ufw-on
expect ufw-on firewall.host PASS
expect ufw-on firewall.boot PASS
sed -i 's/^ENABLED=yes/ENABLED=no/' /etc/ufw/ufw.conf
run_audit ufw-not-at-boot
expect ufw-not-at-boot firewall.boot WARN
# Read-only on a real system: units, nft, iptables-nft, ip6tables, fail2ban, ufw, sshd -t.
systemctl start fail2ban; sleep 2
snap() { find /etc /var/lib /var/cache/apt /root -xdev -type f -print0 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null | sort; nft list ruleset; }
before=$(mktemp); after=$(mktemp)
snap > "$before"
bash "$AUDIT" >/dev/null 2>&1; bash "$AUDIT" --json >/dev/null 2>&1
snap > "$after"
if diff -q "$before" "$after" >/dev/null; then ok "read-only: no file or nft table changed"
else bad "read-only: audit.sh changed: $(diff "$before" "$after" | grep '^[<>]' | head -n 5 | paste -sd'|' -)"; fi
systemctl stop fail2ban
ufw --force disable >/dev/null; nft flush ruleset
ip -6 addr del 2001:db8:1::5/64 dev "$IFACE" 2>/dev/null

step "kernel: container SKIPs, per-interface redirects"
run_audit kernel
expect kernel kernel.host SKIP
expect kernel kernel.apparmor SKIP PASS
v=$(cat "/proc/sys/net/ipv6/conf/$IFACE/accept_redirects" 2>/dev/null)
if [[ "$v" == 1 ]]; then
  msg_has kernel kernel.sysctl "net\.ipv6\.conf\.$IFACE\.accept_redirects=1" "interface value reported with all/default=0"
else
  note "$IFACE has IPv6 accept_redirects=${v:-?}"
fi

finish
