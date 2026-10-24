#!/usr/bin/env bash
# Validate every config template in assets/ with the tool that consumes it, on a real distro.
# Runs as root inside a disposable Debian/Ubuntu container: tests/in-container.sh <image> templates
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh
. tests/lib.sh
require_disposable_container
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

. /etc/os-release
echo "templates on $PRETTY_NAME"
step "install validators"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt_install openssh-server fail2ban python3-systemd nftables cloud-init systemd apt-utils perl python3-yaml caddy docker.io
ok "packages installed"

ssh-keygen -q -t ed25519 -N '' -C test -f "$WORK/id" && TEST_PUBKEY=$(cat "$WORK/id.pub")
export TEST_PUBKEY

# ---------------------------------------------------------------------- sshd
step "sshd drop-in ($(ssh -V 2>&1))"
prepare_sshd
# Reproduce the cloud-init trap the template is named 00- for: a later drop-in that
# re-enables passwords must lose, because sshd keeps the first value it reads.
printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
install -m 644 "$ASSETS/ssh/00-vps-forge.conf" /etc/ssh/sshd_config.d/00-vps-forge.conf
if /usr/sbin/sshd -t; then ok "sshd -t accepts 00-vps-forge.conf"; else bad "sshd -t rejects 00-vps-forge.conf"; fi
for kv in passwordauthentication=no permitrootlogin=no kbdinteractiveauthentication=no \
          authenticationmethods=publickey allowgroups=sshusers maxauthtries=5 x11forwarding=no; do
  got=$(sshd_value "${kv%%=*}")
  [[ "$got" == "${kv#*=}" ]] && ok "effective ${kv%%=*} = $got (wins over 50-cloud-init.conf)" \
    || bad "effective ${kv%%=*} = '$got', want '${kv#*=}'"
done
rm -f /etc/ssh/sshd_config.d/*.conf

# ---------------------------------------------------------------- fail2ban
step "fail2ban jail ($(fail2ban-client --version 2>/dev/null | head -n 1))"
fill "$ASSETS/fail2ban/vps-forge.local" "$WORK/vps-forge.local" || true
install -m 644 "$WORK/vps-forge.local" /etc/fail2ban/jail.d/vps-forge.local
touch /var/log/fail2ban.log
if out=$(fail2ban-client -t 2>&1); then ok "fail2ban-client -t"; else bad "fail2ban-client -t: $(tail -n 3 <<<"$out")"; fi
dump=$(fail2ban-client -d 2>/dev/null)
for jail in sshd recidive; do
  grep -q "\['add', '$jail'" <<<"$dump" && ok "jail $jail enabled" || bad "jail $jail missing from fail2ban-client -d"
done
grep -q "\['add', 'sshd', 'systemd'\]" <<<"$dump" && ok "sshd jail uses the systemd backend" || bad "sshd jail backend is not systemd"
grep -qE "'sshd', 'action', .*\\['port', '22'\\]" <<<"$dump" && ok "sshd jail port = filled <ssh-port> (22)" || bad "sshd jail action port is not the filled <ssh-port> (22)"
# recidive bans only the SSH port: an all-ports ban on a web server locks out whole CGNAT ranges.
grep -qE "'recidive', 'action', 'nftables-multiport', .*\\['port', '22'\\]" <<<"$dump" \
  && ok "recidive bans with nftables-multiport on the filled <ssh-port> (22)" || bad "recidive action is not nftables-multiport on port 22"
grep -q "'recidive', 'action', 'nftables-allports'" <<<"$dump" && bad "recidive still has the all-ports action" || ok "recidive has no all-ports action"
rm -f /etc/fail2ban/jail.d/vps-forge.local

# --------------------------------------------------------------------- apt
step "apt.conf.d"
for f in "$ASSETS"/apt/*; do
  if out=$(apt-config -c "$f" dump 2>&1); then ok "apt-config parses $(basename "$f")"; else bad "apt-config $(basename "$f"): $out"; fi
done
grep -q 'APT::Periodic::Unattended-Upgrade "1"' <<<"$(apt-config -c "$ASSETS/apt/20auto-upgrades" dump)" \
  && ok "unattended upgrades enabled" || bad "APT::Periodic::Unattended-Upgrade is not 1"

# -------------------------------------------------------------- needrestart
step "needrestart"
perl -c "$ASSETS/needrestart/50-vps-forge.conf" >/dev/null 2>&1 && ok "perl -c 50-vps-forge.conf" || bad "needrestart conf is not valid perl"

# ------------------------------------------------------------------ sysctl
step "sysctl"
missing=""
while IFS='=' read -r key _; do
  key=$(tr -d '[:space:]' <<<"$key")
  [[ -z "$key" || "$key" == \#* ]] && continue
  compgen -G "/proc/sys/${key//./\/}" >/dev/null || missing+="$key "
done < "$ASSETS/sysctl/99-vps-forge.conf"
# Catches typos: a misspelled key makes `sysctl --system` skip the line with only a warning.
# A few keys are global to the host and invisible from a container's network namespace.
hostonly=""; unknown=""
for k in $missing; do
  case "$k" in net.core.default_qdisc) hostonly+="$k " ;; *) unknown+="$k " ;; esac
done
[[ -z "$unknown" ]] && ok "every sysctl key exists in this kernel${hostonly:+ (host-global, not visible here: ${hostonly% })}" \
  || bad "sysctl keys unknown to this kernel: $unknown"
grep -vE '^[[:space:]]*(#|$)' "$ASSETS/sysctl/99-vps-forge.conf" | grep -vqE '^[a-z0-9_.*]+ = [0-9a-z]+$' \
  && bad "sysctl lines must be 'key = value'" || ok "sysctl syntax"

# ---------------------------------------------------------------- journald
step "journald"
python3 -I - "$ASSETS/journald/10-vps-forge.conf" <<'PY' && ok "journald drop-in keys" || bad "journald drop-in"
import configparser, sys
known = {"Storage","Compress","Seal","SplitMode","SyncIntervalSec","RateLimitIntervalSec","RateLimitBurst",
         "SystemMaxUse","SystemKeepFree","SystemMaxFileSize","SystemMaxFiles","RuntimeMaxUse","RuntimeKeepFree",
         "RuntimeMaxFileSize","RuntimeMaxFiles","MaxRetentionSec","MaxFileSec","ForwardToSyslog","ForwardToKMsg",
         "ForwardToConsole","ForwardToWall","MaxLevelStore","MaxLevelSyslog","MaxLevelKMsg","MaxLevelConsole",
         "MaxLevelWall","LineMax","ReadKMsg","Audit"}
c = configparser.ConfigParser(); c.optionxform = str; c.read(sys.argv[1])
assert c.sections() == ["Journal"], c.sections()
bad = set(c["Journal"]) - known
assert not bad, f"unknown keys: {bad}"
PY

# ----------------------------------------------------------- systemd units
step "systemd units"
install -m 755 "$ASSETS/restic/vps-forge-backup.sh" /usr/local/sbin/vps-forge-backup.sh
install -m 755 "$ASSETS/firewall/ufw-cloudflare-sync.sh" /usr/local/sbin/ufw-cloudflare-sync.sh
units=("$ASSETS"/restic/*.service "$ASSETS"/restic/*.timer "$ASSETS"/firewall/*.service "$ASSETS"/firewall/*.timer)
cp "${units[@]}" /etc/systemd/system/
for u in "${units[@]}"; do
  n=$(basename "$u")
  # Without a running systemd, verify still parses the unit; ignore complaints about the
  # missing manager and about dependencies that only exist on a booted host.
  out=$(SYSTEMD_LOG_LEVEL=warning systemd-analyze verify "/etc/systemd/system/$n" 2>&1 \
        | grep -vE 'Failed to (connect|create bus|initialize)|ufw\.service|System has not been booted|-.mount|not found' || true)
  [[ -z "$out" ]] && ok "systemd-analyze verify $n" || bad "$n: $out"
done
for t in "$ASSETS"/restic/*.timer "$ASSETS"/firewall/*.timer; do
  cal=$(awk -F= '/^OnCalendar=/{print $2}' "$t")
  systemd-analyze calendar "$cal" >/dev/null 2>&1 && ok "OnCalendar '$cal' in $(basename "$t")" || bad "bad OnCalendar '$cal' in $(basename "$t")"
done

# ------------------------------------------------------------------- caddy
step "Caddyfile"
if command -v caddy >/dev/null; then
  fill "$ASSETS/caddy/Caddyfile" "$WORK/Caddyfile" || true
  if out=$(caddy validate --adapter caddyfile --config "$WORK/Caddyfile" 2>&1); then ok "caddy validate ($(caddy version | cut -d' ' -f1))"
  else bad "caddy validate: $(grep -iE 'error|invalid' <<<"$out" | head -n 3)"; fi
  caddy fmt "$WORK/Caddyfile" | diff -q - "$WORK/Caddyfile" >/dev/null && ok "Caddyfile is caddy-fmt clean" || bad "Caddyfile is not formatted (caddy fmt --diff)"
else
  note "caddy not packaged for $PRETTY_NAME"
fi

# ------------------------------------------------------------------ docker
step "docker daemon.json"
if command -v dockerd >/dev/null && dockerd --help 2>&1 | grep -q -- '--validate'; then
  if out=$(dockerd --validate --config-file "$ASSETS/docker/daemon.json" 2>&1); then ok "dockerd --validate ($(dockerd --version))"
  else bad "dockerd --validate: $out"; fi
else
  note "dockerd --validate needs Docker 23+ (not packaged for $PRETTY_NAME)"
fi

# -------------------------------------------------------------- cloud-init
step "cloud-init ($(cloud-init --version 2>&1))"
fill "$ASSETS/cloud-init.yaml" "$WORK/cloud-init.yaml" || true
if out=$(cloud-init schema --config-file "$WORK/cloud-init.yaml" 2>&1); then ok "cloud-init schema"
else bad "cloud-init schema: $out"; fi
# The files cloud-init writes must pass the same validators as the standalone templates and
# keep the same security-relevant values.
python3 -I - "$WORK/cloud-init.yaml" "$WORK" <<'PY' || bad "cannot extract write_files"
import sys, yaml, os
doc = yaml.safe_load(open(sys.argv[1]))
for f in doc["write_files"]:
    out = os.path.join(sys.argv[2], "cloud" + f["path"].replace("/", "_"))
    open(out, "w").write(f["content"])
PY
std=()
install -m 644 "$ASSETS/ssh/00-vps-forge.conf" /etc/ssh/sshd_config.d/00-vps-forge.conf
for k in passwordauthentication permitrootlogin kbdinteractiveauthentication authenticationmethods allowgroups maxauthtries; do std+=("$k=$(sshd_value "$k")"); done
install -m 644 "$WORK/cloud_etc_ssh_sshd_config.d_00-vps-forge.conf" /etc/ssh/sshd_config.d/00-vps-forge.conf
if /usr/sbin/sshd -t; then ok "sshd -t accepts cloud-init's sshd drop-in"; else bad "sshd -t rejects cloud-init's sshd drop-in"; fi
for kv in "${std[@]}"; do
  got=$(sshd_value "${kv%%=*}")
  [[ "$got" == "${kv#*=}" ]] || bad "cloud-init sshd drop-in: ${kv%%=*} = '$got', template has '${kv#*=}'"
done
ok "cloud-init sshd values match the template"
rm -f /etc/ssh/sshd_config.d/00-vps-forge.conf
install -m 644 "$WORK/cloud_etc_fail2ban_jail.d_vps-forge.local" /etc/fail2ban/jail.d/vps-forge.local
if out=$(fail2ban-client -t 2>&1); then ok "fail2ban-client -t accepts cloud-init's jail"; else bad "cloud-init jail: $(tail -n 3 <<<"$out")"; fi
rm -f /etc/fail2ban/jail.d/vps-forge.local
apt-config -c "$WORK/cloud_etc_apt_apt.conf.d_20auto-upgrades" dump >/dev/null 2>&1 && ok "cloud-init 20auto-upgrades parses" || bad "cloud-init 20auto-upgrades"
# The crypto drop-in is generated on the target by runcmd; run that step here, on this OpenSSH.
python3 -I -c 'import sys, yaml
c = [c for c in yaml.safe_load(open(sys.argv[1]))["runcmd"] if isinstance(c, list) and c[:2] == ["bash", "-c"] and "01-vps-forge-crypto.conf" in c[2]]
assert len(c) == 1; open(sys.argv[2], "w").write(c[0][2])' "$WORK/cloud-init.yaml" "$WORK/crypto.sh" || bad "cloud-init: no runcmd step generates the crypto drop-in"
crypto=/etc/ssh/sshd_config.d/01-vps-forge-crypto.conf
if bash "$WORK/crypto.sh" && [[ -s $crypto ]] && /usr/sbin/sshd -t; then
  want=$(awk '$1 == "KexAlgorithms" { print $2 }' "$crypto")
  got=$(sshd_value kexalgorithms)
  [[ -n "$want" && "$got" == "$want" ]] && ok "cloud-init generates a valid crypto drop-in (kex $got)" || bad "cloud-init crypto drop-in: kex '$got', file has '$want'"
else
  bad "cloud-init crypto step left no valid $crypto"
fi
rm -f "$crypto"
# ufw matches in order and `limit` ignores fail2ban's ignoreip, so the admin allow must come first.
python3 -I - "$WORK/cloud-init.yaml" <<'PY' && ok "cloud-init allows the filled <admin-ip> before ufw limit" || bad "cloud-init: no admin allow before ufw limit"
import sys, yaml
ufw = [c for c in yaml.safe_load(open(sys.argv[1]))["runcmd"] if isinstance(c, list) and c[:1] == ["ufw"]]
admin = [i for i, c in enumerate(ufw) if c[1] == "allow" and "198.51.100.7" in c]
limit = [i for i, c in enumerate(ufw) if c[1] == "limit"]
assert admin and limit and admin[0] < limit[0], (admin, limit)
PY

# Drift check: every file cloud-init writes needs a standalone template (found by the
# "<path>: managed by vps-forge" header) with the same effective content, i.e. after fill()
# and with comments, blank lines and indentation ignored. Order counts (fail2ban sections).
effective() { grep -vE '^[[:space:]]*(#|//|$)' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
paths=$(python3 -I -c 'import sys, yaml; [print(f["path"]) for f in yaml.safe_load(open(sys.argv[1]))["write_files"]]' "$WORK/cloud-init.yaml")
for path in $paths; do
  tpl=$(grep -rlxF -e "# $path: managed by vps-forge" -e "// $path: managed by vps-forge" "$ASSETS" | head -n 1)
  if [[ -z "$tpl" ]]; then bad "cloud-init writes $path, but no template in assets/ has that header"; continue; fi
  fill "$tpl" "$WORK/std" || true
  if d=$(diff <(effective "$WORK/std") <(effective "$WORK/cloud${path//\//_}")); then
    ok "cloud-init $path matches ${tpl#"$ASSETS"/}"
  else
    bad "cloud-init $path drifted from ${tpl#"$ASSETS"/} (< template, > cloud-init): $(grep '^[<>]' <<<"$d" | head -n 6 | paste -sd'|' -)"
  fi
done

finish
