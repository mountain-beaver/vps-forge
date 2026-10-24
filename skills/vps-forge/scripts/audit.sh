#!/usr/bin/env bash
# vps-forge audit: read-only security and health audit for Debian/Ubuntu servers.
#
# Usage:  sudo bash audit.sh [--json] [--quiet] [--no-color]
#         ssh host 'sudo bash -s -- --json' < audit.sh
#
# Changes nothing on the system. Runs without root, but then several checks are SKIPped.
# Exit status: 0 = no FAIL, 1 = at least one FAIL, 2 = usage error.
# Part of vps-forge (MIT). https://github.com/mountain-beaver/vps-forge

set -uo pipefail
export LC_ALL=C

VERSION="1.0.1"
JSON=0
QUIET=0
COLOR=1
[[ -t 1 ]] || COLOR=0

usage() {
  sed -n '2,9p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  echo "Options: --json  machine-readable output | --quiet  hide PASS/INFO lines | --no-color"
}

for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

IS_ROOT=0
[[ ${EUID:-$(id -u)} -eq 0 ]] && IS_ROOT=1

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- results ---
declare -a R_SECTION=() R_ID=() R_STATUS=() R_MSG=()
CUR_SECTION="general"
section() { CUR_SECTION="$1"; }
MSG_MAX=800
# Messages carry text from the server (file and process names, key comments). Control
# characters could rewrite the terminal line (a fake PASS over a WARN), so flatten line breaks,
# drop C0/C1 controls and cap the length without cutting a UTF-8 sequence in half.
clean() {
  local m=${1//[$'\n\r\t']/ }
  m=${m//[$'\001'-$'\037'$'\177']/}
  m=${m//$'\xc2'[$'\x80'-$'\x9f']/}
  if (( ${#m} > MSG_MAX )); then
    m=${m:0:MSG_MAX}
    while [[ "${m: -1}" == [$'\x80'-$'\xbf'] ]]; do m=${m%?}; done
    [[ "${m: -1}" == [$'\xc0'-$'\xff'] ]] && m=${m%?}
    m+="…"
  fi
  printf '%s' "$m"
}
# Attacker-controllable names (temp files, process names, key comments): printable ASCII only,
# capped. The agent reading the report must treat them as data, never as instructions.
untrusted() { # text [max]
  local s=${1//[^ -~]/?} n=${2:-120}
  (( ${#s} > n )) && s="${s:0:n}..."
  printf '%s' "$s"
}
report() { # status id message
  R_SECTION+=("$CUR_SECTION"); R_STATUS+=("$1"); R_ID+=("$2"); R_MSG+=("$(clean "$3")")
}
pass() { report PASS "$1" "$2"; }
warn() { report WARN "$1" "$2"; }
fail() { report FAIL "$1" "$2"; }
info() { report INFO "$1" "$2"; }
skip() { report SKIP "$1" "$2"; }
need_root() { # id what
  if (( ! IS_ROOT )); then skip "$1" "needs root: $2"; return 1; fi
  return 0
}
join_lines() { paste -sd ';' - | sed 's/;/; /g'; }

# ------------------------------------------------------------------ system ---
section system
OS_ID="unknown"; OS_VER="unknown"; OS_PRETTY="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
  # shellcheck disable=SC1091
  OS_VER=$(. /etc/os-release; echo "${VERSION_ID:-unknown}")
  # shellcheck disable=SC1091
  OS_PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")
fi
TODAY=$(date -u +%F)
case "$OS_ID:$OS_VER" in
  debian:12)
    if [[ "$TODAY" < 2026-07-11 ]]; then pass os.supported "$OS_PRETTY"
    else warn os.supported "$OS_PRETTY is in LTS since 2026-07-11 (fewer packages get security fixes, ends 2028-06-30): plan an upgrade to Debian 13"; fi ;;
  ubuntu:22.04)
    if [[ "$TODAY" < 2027-06-01 ]]; then pass os.supported "$OS_PRETTY"
    else warn os.supported "$OS_PRETTY standard support ended 2027-06-01: security fixes need Ubuntu Pro (ESM); plan an upgrade to 24.04"; fi ;;
  debian:13|ubuntu:24.04|ubuntu:26.04)
    pass os.supported "$OS_PRETTY" ;;
  debian:11|debian:10|ubuntu:20.04|ubuntu:18.04)
    fail os.supported "$OS_PRETTY is past standard support; plan a rebuild on a current release" ;;
  *) warn os.supported "$OS_PRETTY is not a tested target (Debian 12/13, Ubuntu 22.04/24.04/26.04)" ;;
esac
info os.kernel "kernel $(uname -r), arch $(uname -m)"

if have systemd-detect-virt; then
  VIRT=$(systemd-detect-virt 2>/dev/null || true)
  case "$VIRT" in
    openvz|lxc|lxc-libvirt|systemd-nspawn|docker|podman|wsl)
      warn os.virt "container-based ($VIRT): kernel tuning, swap, modules and some firewall features may be unavailable" ;;
    "") info os.virt "virtualization: unknown" ;;
    *) info os.virt "virtualization: $VIRT" ;;
  esac
fi
# In a container the host owns kernel.* sysctls, AppArmor and swap; net.* lives in the netns.
CONTAINER=""
if have systemd-detect-virt; then CONTAINER=$(systemd-detect-virt --container 2>/dev/null)
elif [[ -e /run/.containerenv ]]; then CONTAINER=podman
elif [[ -e /.dockerenv ]]; then CONTAINER=docker
elif [[ -d /proc/vz && ! -d /proc/bc ]]; then CONTAINER=openvz
fi
[[ "$CONTAINER" == none ]] && CONTAINER=""
# Unit state checks need a running systemd; stubs and chroots must not produce verdicts.
HAVE_SYSTEMD=0
[[ -d /run/systemd/system ]] && have systemctl && HAVE_SYSTEMD=1
unit_enabled() { # unit -> 0 when it starts at boot
  case "$(systemctl is-enabled "$1" 2>/dev/null)" in
    enabled|enabled-runtime|static|alias|generated) return 0 ;;
  esac
  return 1
}

if [[ -f /var/run/reboot-required ]]; then
  pkgs=$(head -c 300 /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')
  warn os.reboot "reboot required${pkgs:+ (by: $pkgs)}"
else
  newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n 1)
  if [[ -n "$newest" && "$newest" != "$(uname -r)" ]]; then
    warn os.reboot "running kernel $(uname -r) but $newest is installed; reboot to activate it"
  else
    pass os.reboot "no reboot pending"
  fi
fi

section updates
if have apt-get; then
  lists_age_days=""
  newest_list=$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
  if [[ -n "$newest_list" ]]; then
    lists_age_days=$(( ( $(date +%s) - ${newest_list%.*} ) / 86400 ))
  fi
  # Empty cache paths: a simulation must not rebuild pkgcache.bin/srcpkgcache.bin.
  sim=$(apt-get -s -o Debug::NoLocking=1 -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= upgrade 2>/dev/null | grep '^Inst ' || true)
  total=0; sec=0
  if [[ -n "$sim" ]]; then
    total=$(grep -c '^Inst ' <<<"$sim")
    sec=$(grep -ci 'security' <<<"$sim" || true)
  fi
  age_note=""
  [[ -n "$lists_age_days" && "$lists_age_days" -ge 2 ]] && age_note=" (package lists are ${lists_age_days} days old; counts may be low)"
  if (( sec > 0 )); then
    warn updates.pending "$sec security update(s) pending, $total total$age_note"
  elif (( total > 0 )); then
    info updates.pending "$total non-security update(s) pending$age_note"
  else
    pass updates.pending "no pending updates$age_note"
  fi
fi

if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
  # apt.systemd.daily: each APT::Periodic interval is a number of days (0 = off) or "always".
  periodic() { apt-config dump "APT::Periodic::$1" 2>/dev/null | sed -n 's/.*"\(.*\)";/\1/p' | tail -n 1; }
  p_on() { [[ "$1" == always || ( "$1" =~ ^[0-9]+$ && "$1" -ge 1 ) ]]; }
  uu=$(periodic Unattended-Upgrade); upl=$(periodic Update-Package-Lists)
  uu_off=""
  if (( HAVE_SYSTEMD )); then
    for t in apt-daily.timer apt-daily-upgrade.timer; do
      st=$(systemctl is-enabled "$t" 2>/dev/null)
      case "$st" in masked*|disabled) uu_off+="${uu_off:+, }$t is $st" ;; esac
    done
  fi
  if ! p_on "$uu"; then
    fail updates.unattended "unattended-upgrades installed but not enabled (APT::Periodic::Unattended-Upgrade=${uu:-unset})"
  elif ! p_on "$upl"; then
    fail updates.unattended "unattended-upgrades enabled, but APT::Periodic::Update-Package-Lists=${upl:-unset}: package lists are never refreshed, so it never sees new security updates. Set it to \"1\""
  elif [[ -n "$uu_off" ]]; then
    fail updates.unattended "unattended-upgrades configured, but $uu_off: it never runs. systemctl unmask and enable --now apt-daily.timer apt-daily-upgrade.timer"
  elif [[ "$uu" != 1 && "$uu" != always ]] || [[ "$upl" != 1 && "$upl" != always ]]; then
    warn updates.unattended "unattended-upgrades runs only every $uu day(s) on lists refreshed every $upl day(s); set both APT::Periodic values to \"1\""
  else
    pass updates.unattended "unattended-upgrades enabled"
  fi
  log=/var/log/unattended-upgrades/unattended-upgrades.log
  if [[ -f "$log" ]]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$log") ) / 86400 ))
    if (( age <= 3 )); then pass updates.last_run "last unattended-upgrades activity ${age}d ago"
    else warn updates.last_run "no unattended-upgrades activity for ${age} days"; fi
  else
    info updates.last_run "no unattended-upgrades log yet"
  fi
  reboot_auto=$(apt-config dump Unattended-Upgrade::Automatic-Reboot 2>/dev/null | sed -n 's/.*"\(.*\)";/\1/p' | tail -n 1)
  info updates.auto_reboot "automatic reboot: ${reboot_auto:-false}"
else
  fail updates.unattended "unattended-upgrades is not installed: security fixes depend on someone remembering"
fi
if dpkg-query -W -f='${Status}' needrestart 2>/dev/null | grep -q 'install ok installed'; then
  pass updates.needrestart "needrestart installed"
else
  info updates.needrestart "needrestart not installed (services may keep running old libraries after updates)"
fi
# Ubuntu Pro: read the state file. `pro status` rewrites it, logs and calls contracts.canonical.com.
pj=/var/lib/ubuntu-advantage/status.json
if [[ -r "$pj" ]]; then
  if have python3; then
    pro=$(python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
lp=[s.get("status") or "-" for s in d.get("services") or [] if s.get("name")=="livepatch"]
print("yes" if d.get("attached") else "no", lp[0] if lp else "-")' "$pj" 2>/dev/null)
  elif have jq; then
    pro=$(jq -r '[(if .attached then "yes" else "no" end), ([(.services // [])[] | select(.name=="livepatch") | (.status // "-")] + ["-"])[0]] | join(" ")' "$pj" 2>/dev/null)
  elif grep -qE '"attached": *true' "$pj"; then pro="yes ?"
  else pro="no -"; fi
  case "$pro" in
    yes\ *) info updates.pro "Ubuntu Pro attached, livepatch: $(untrusted "${pro#yes }" 20)" ;;
    no\ *) info updates.pro "Ubuntu Pro not attached (no livepatch, no ESM)" ;;
  esac
fi

# -------------------------------------------------------------------- ssh ---
section ssh
SSHD_T=""; SSHD=""; SSH_PORTS=""; SSH_SOCK_PORTS=""
# Where sshd really listens: its own sockets, plus ssh.socket when socket activation is on
# (then sshd gets the socket from systemd and its Port setting is not used for listening).
SS_SSHD_PORTS=$(ss -Htlnp 2>/dev/null | awk '/\("sshd",/{p=$4; sub(/.*:/, "", p); print p}' | sort -un)
if (( HAVE_SYSTEMD )) && systemctl is-active --quiet ssh.socket 2>/dev/null; then
  SSH_SOCK_PORTS=$(systemctl show -p Listen --value ssh.socket 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | tr -dc '0-9\n' | sort -un)
fi
# The address and port an outside client connects to, for Match LocalAddress/LocalPort.
LADDR=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i=="src") {print $(i+1); exit}}')
[[ -n "$LADDR" ]] || LADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
LADDR=${LADDR:-192.0.2.10}
SSH_T_NOTE=""
if have sshd || [[ -x /usr/sbin/sshd ]]; then
  SSHD=$(command -v sshd || echo /usr/sbin/sshd)
  if need_root ssh.effective "sshd -T"; then
    # Validity comes from sshd -t. sshd -T also fails on a valid config with Match LocalPort or
    # LocalAddress, because it needs a connection to evaluate them.
    if ! t_out=$("$SSHD" -t 2>&1); then
      if grep -q 'privilege separation directory' <<<"$t_out"; then
        skip ssh.effective "sshd -t needs /run/sshd, which exists only while sshd runs (socket-activated and idle?). Connect once over SSH and re-run"
      else
        # An invalid config keeps the running daemon alive, but the next restart, reload or
        # reboot leaves the server without SSH. The other ssh.* checks cannot run.
        fail ssh.effective "sshd config is invalid (sshd -t: $(grep -m 1 -v '^[[:space:]]*$' <<<"$t_out")): the next ssh restart or reboot fails and locks you out; ssh.* checks skipped. Fix it and confirm with 'sshd -t'"
      fi
    elif SSHD_T=$("$SSHD" -T 2>&1); then
      :
    else
      t_err=$(grep -m 1 -v '^[[:space:]]*$' <<<"$SSHD_T" | sed 's/[.[:space:]]*$//')
      lport=$(printf '%s\n' $SS_SSHD_PORTS $SSH_SOCK_PORTS | head -n 1)
      if SSHD_T=$("$SSHD" -T -C "user=vpsforge-check,host=203.0.113.1,addr=203.0.113.1,laddr=$LADDR,lport=${lport:-22}" 2>&1); then
        SSH_T_NOTE=" (values for an outside connection to $LADDR:${lport:-22}: sshd -T alone fails with: $t_err)"
      else
        warn ssh.effective "sshd -t accepts the config, but sshd -T cannot evaluate it ($t_err); ssh.* checks skipped. Check by hand: sshd -T -C user=<admin>,host=<your ip>,addr=<your ip>,laddr=<server ip>,lport=<port>"
        SSHD_T=""
      fi
    fi
  fi
else
  info ssh.present "OpenSSH server not installed"
fi

sget() { awk -v k="$1" 'tolower($1)==k { $1=""; sub(/^ /,""); print; exit }' <<<"$SSHD_T"; }
sall() { awk -v k="$1" 'tolower($1)==k { $1=""; sub(/^ /,""); print }' <<<"$SSHD_T"; }

SSH_PORTS=$( { printf '%s\n' $SS_SSHD_PORTS $SSH_SOCK_PORTS; [[ -n "$SSH_SOCK_PORTS" ]] || sall port; } | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -)

if [[ -n "$SSHD" ]] && (( HAVE_SYSTEMD )); then
  # A config that only works until the next reboot is a delayed lockout.
  ssh_on=""; ssh_units=0
  for u in ssh.service ssh.socket sshd.service sshd.socket; do
    st=$(systemctl is-enabled "$u" 2>/dev/null)
    [[ -n "$st" && "$st" != not-found ]] && ssh_units=1
    # sshd.service is Debian's alias of ssh.service; it counts only on its own
    [[ "$u" == sshd.* && -n "$ssh_on" ]] && continue
    unit_enabled "$u" && ssh_on+="${ssh_on:+, }$u"
  done
  if [[ -n "$ssh_on" ]]; then pass ssh.boot "SSH starts at boot ($ssh_on enabled)"
  elif (( ssh_units )); then fail ssh.boot "neither ssh.service nor ssh.socket is enabled: SSH does not come back after a reboot. systemctl enable ssh"
  fi
fi

if [[ -n "$SSHD_T" ]]; then
  if [[ -n "$SSH_SOCK_PORTS" ]] && [[ "$(sall port | sort -un | paste -sd' ' -)" != "$(paste -sd' ' - <<<"$SSH_SOCK_PORTS")" ]]; then
    info ssh.port "listening port(s): ${SSH_PORTS// /,} (ssh.socket listens on $(paste -sd, - <<<"$SSH_SOCK_PORTS"); sshd_config Port $(sall port | paste -sd, -) is not used for listening while ssh.socket is active)$SSH_T_NOTE"
  else
    info ssh.port "listening port(s): ${SSH_PORTS// /,}$SSH_T_NOTE"
  fi

  v=$(sget permitrootlogin)
  case "$v" in
    no) pass ssh.root_login "root login disabled" ;;
    prohibit-password|without-password) warn ssh.root_login "root login allowed with keys (PermitRootLogin $v); use an admin user + sudo" ;;
    forced-commands-only) info ssh.root_login "root login only for forced commands" ;;
    *) fail ssh.root_login "root login allowed (PermitRootLogin ${v:-?})" ;;
  esac

  methods=$(sget authenticationmethods)
  # AuthenticationMethods: space = alternatives, comma = all required. Real 2FA means EVERY
  # alternative list contains publickey. "publickey keyboard-interactive" lets a password alone in.
  key_required=0
  if [[ -n "$methods" && "$methods" != "any" ]]; then
    key_required=1
    for list in $methods; do [[ ",$list," == *",publickey,"* ]] || key_required=0; done
    if (( ! key_required )); then
      fail ssh.authmethods "AuthenticationMethods '$methods' allows a login without a key (space = OR, comma = AND)"
    fi
  fi

  v=$(sget passwordauthentication)
  if [[ "$v" == "no" ]]; then
    pass ssh.password_auth "password authentication disabled"
  elif (( key_required )) && [[ ",${methods// /,}," == *",password,"* ]]; then
    # publickey,password: the password is a second factor, and setting it to no breaks sshd -t.
    info ssh.password_auth "password only as a second factor after a key (AuthenticationMethods $methods); PasswordAuthentication yes is required for that"
  else
    srcs=$(grep -lsiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | paste -sd, -)
    if (( key_required )); then
      info ssh.password_auth "PasswordAuthentication yes${srcs:+ (set in: $srcs)} has no effect while AuthenticationMethods $methods requires a key; set it to no so removing AuthenticationMethods can't bring passwords back"
    else
    fail ssh.password_auth "password authentication enabled${srcs:+ (set in: $srcs; the first value read wins)}"
    fi
  fi

  v=$(sget kbdinteractiveauthentication); [[ -z "$v" ]] && v=$(sget challengeresponseauthentication)
  g_kbd=$v
  usepam=$(sget usepam)
  if [[ "$v" == "no" ]]; then
    pass ssh.kbdinteractive "keyboard-interactive disabled"
  elif (( key_required )); then
    pass ssh.kbdinteractive "keyboard-interactive only as a second factor after a key ($methods)"
  elif [[ "$usepam" == "yes" ]]; then
    fail ssh.kbdinteractive "keyboard-interactive enabled with UsePAM: passwords can still be used"
  else
    warn ssh.kbdinteractive "keyboard-interactive enabled"
  fi

  [[ "$(sget permitemptypasswords)" == "yes" ]] && fail ssh.empty_passwords "PermitEmptyPasswords yes"
  [[ "$(sget pubkeyauthentication)" == "no" ]] && warn ssh.pubkey "PubkeyAuthentication no"

  v=$(sget maxauthtries)
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v <= 5 )); then pass ssh.maxauthtries "MaxAuthTries $v"
  else warn ssh.maxauthtries "MaxAuthTries ${v:-?} (5 or fewer recommended)"; fi

  [[ "$(sget x11forwarding)" == "yes" ]] && warn ssh.x11 "X11Forwarding yes (not needed on servers)"

  au=$(sall allowusers | paste -sd' ' -); ag=$(sall allowgroups | paste -sd' ' -)
  if [[ -n "$au$ag" ]]; then
    # An allowlist nobody matches (empty group, typo in a user name) locks everyone out.
    # Collect accounts that certainly match; wildcard patterns make the result a lower bound.
    al_wild=0; al_missing=""; al_users=""; al_groups=""
    read -ra al_list <<<"$au"
    for e in "${al_list[@]}"; do
      u=${e%%@*}
      if [[ "$u" == *[*?!]* ]]; then al_wild=1
      elif getent passwd "$u" >/dev/null; then al_users+=" $u"
      else al_missing+=" user '$u' does not exist;"; fi
    done
    read -ra al_list <<<"$ag"
    for g in "${al_list[@]}"; do
      if [[ "$g" == *[*?!]* ]]; then al_wild=1; continue; fi
      if ! gr=$(getent group "$g"); then al_missing+=" group '$g' does not exist;"; continue; fi
      gmem=$(cut -d: -f4 <<<"$gr"); gid=$(cut -d: -f3 <<<"$gr")
      # supplementary members plus accounts whose primary group it is
      gmem="${gmem//,/ } $(getent passwd | awk -F: -v g="$gid" '$4==g{print $1}' | paste -sd' ' -)"
      [[ -z "${gmem// /}" ]] && al_missing+=" group '$g' has no members;"
      al_groups+=" $gmem"
    done
    if [[ -n "$au" && -n "$ag" ]]; then cand=$(comm -12 <(tr ' ' '\n' <<<"$al_users" | sort -u) <(tr ' ' '\n' <<<"$al_groups" | sort -u))
    else cand=$(tr ' ' '\n' <<<"$al_users $al_groups" | sort -u); fi
    # DenyUsers/DenyGroups are checked first by sshd and override the allowlist. Only patterns
    # that deny from every address count (user@host and negations are left out).
    read -ra deny_u <<<"$(sall denyusers | paste -sd' ' -)"
    read -ra deny_g <<<"$(sall denygroups | paste -sd' ' -)"
    ssh_denied() { # user
      local p g
      for p in "${deny_u[@]}"; do
        [[ "$p" == *[@!]* ]] && continue
        # shellcheck disable=SC2053  # sshd patterns: * and ? work like globs
        [[ "$1" == $p ]] && return 0
      done
      (( ${#deny_g[@]} )) || return 1
      for g in $(id -nG "$1" 2>/dev/null); do
        for p in "${deny_g[@]}"; do
          [[ "$p" == *!* ]] && continue
          # shellcheck disable=SC2053
          [[ "$g" == $p ]] && return 0
        done
      done
      return 1
    }
    al_ok=""
    for u in $cand; do
      pw=$(getent passwd "$u") || continue
      sh=${pw##*:}
      [[ "$sh" == */nologin || "$sh" == */false ]] && continue
      [[ "$u" == root || "${pw#*:*:}" == 0:* ]] && [[ "$(sget permitrootlogin)" == no ]] && continue
      if ssh_denied "$u"; then al_missing+=" '$u' is excluded by DenyUsers/DenyGroups;"; continue; fi
      al_ok+="$u "
    done
    if [[ -n "$al_ok" ]]; then
      pass ssh.allowlist "login restricted:${au:+ AllowUsers $au}${ag:+ AllowGroups $ag}; can log in: $(head -c 120 <<<"$al_ok")"
    elif (( al_wild )); then
      info ssh.allowlist "login restricted by wildcard patterns:${au:+ AllowUsers $au}${ag:+ AllowGroups $ag}; cannot confirm that any account matches, check that your admin user does"
    else
      fail ssh.allowlist "no existing account with a login shell matches${au:+ AllowUsers $au}${ag:+ AllowGroups $ag}:${al_missing:- members have no login shell or are root with PermitRootLogin no;} nobody can log in over SSH. Keep this session open and add your admin user"
    fi
  else
    warn ssh.allowlist "no AllowUsers/AllowGroups: any account with a key can log in"
  fi

  # sshd -T without -C ignores Match blocks. Evaluate an outside connection to every SSH port
  # (Match LocalPort/LocalAddress) for an unknown user and for every account with a login
  # shell: Match User/Group only fire for those, and with user=<nonexistent> a "Match Group
  # sudo" never matches. System accounts count too (postgres has /bin/bash). Capped for speed.
  matches=$(grep -nsE '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | head -n 5 | join_lines)
  if [[ -n "$matches" ]]; then
    m_accounts=$( {
      for e in $au; do e=${e%%@*}; [[ "$e" != *[*?!]* ]] && getent passwd "$e" >/dev/null && echo "$e"; done
      getent passwd | awk -F: '$3!=65534 && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print ($3>=1000 ? 0 : 1), $1}' | sort -s -k1,1n | awk '{print $2}'
    } | grep -vx root | awk '!seen[$0]++' | head -n 20)
    m_ports=$(printf '%s\n' $SSH_PORTS | head -n 4); [[ -n "$m_ports" ]] || m_ports=22
    m_nports=$(wc -l <<<"$m_ports")
    g_pw=$(sget passwordauthentication); g_root=$(sget permitrootlogin)
    m_pw=""; m_kb=""; m_n=0; ert=""
    for u in vpsforge-check root $m_accounts; do
      m_ok=0
      for mp in $m_ports; do
        ev=$("$SSHD" -T -C "user=$u,host=203.0.113.1,addr=203.0.113.1,laddr=$LADDR,lport=$mp" 2>/dev/null) || continue
        m_ok=1
        if [[ "$u" == root ]]; then
          v=$(awk 'tolower($1)=="permitrootlogin"{print $2; exit}' <<<"$ev")
          [[ "$v" == yes || -z "$ert" || ( "$ert" == no && "$v" != no ) ]] && ert=$v
          continue
        fi
        who=$u; [[ "$u" == vpsforge-check ]] && who="any user"
        (( m_nports > 1 )) && who+=" on port $mp"
        epw=$(awk 'tolower($1)=="passwordauthentication"{print $2; exit}' <<<"$ev")
        ekb=$(awk 'tolower($1)=="kbdinteractiveauthentication"{print $2; exit}' <<<"$ev")
        eam=$(awk 'tolower($1)=="authenticationmethods"{$1=""; sub(/^ /,""); print; exit}' <<<"$ev")
        m_key=0
        if [[ -n "$eam" && "$eam" != any ]]; then
          m_key=1
          for list in $eam; do [[ ",$list," == *",publickey,"* ]] || m_key=0; done
        fi
        # the global setting is reported by ssh.password_auth / ssh.kbdinteractive already;
        # publickey,password is 2FA, where PasswordAuthentication yes is required
        if [[ "$epw" == yes && "$g_pw" != yes ]] && ! { (( m_key )) && [[ ",${eam// /,}," == *",password,"* ]]; }; then
          m_pw+="${m_pw:+, }$who"
        fi
        [[ "$ekb" == yes && "$g_kbd" == no ]] && (( ! m_key )) && m_kb+="${m_kb:+, }$who"
      done
      [[ "$u" != root ]] && (( m_ok )) && m_n=$((m_n+1))
    done
    m_bad=""
    [[ -n "$m_pw" ]] && m_bad+="password login for $m_pw; "
    [[ "$ert" == yes && "$g_root" != yes ]] && m_bad+="root login (PermitRootLogin yes); "
    [[ -n "$m_kb" && "$usepam" == yes ]] && m_bad+="keyboard-interactive with UsePAM (passwords) for $m_kb; "
    if (( m_n == 0 )); then
      warn ssh.match "Match blocks could not be evaluated (sshd -T -C failed for every account): $matches. Check them by hand: sshd -T -C user=<admin>,host=<your ip>,addr=<your ip>,laddr=$LADDR,lport=<port>"
    elif [[ -n "$m_bad" ]]; then
      fail ssh.match "Match blocks re-enable ${m_bad%; } for outside connections: $matches"
    elif [[ -n "$m_kb" ]]; then
      warn ssh.match "Match blocks enable keyboard-interactive for $m_kb on outside connections: $matches"
    elif [[ "$ert" == prohibit-password || "$ert" == without-password ]] && [[ "$g_root" == no ]]; then
      warn ssh.match "Match blocks allow root login with keys (PermitRootLogin $ert) for outside connections: $matches"
    else
      info ssh.match "Match blocks present (checked an outside client on port(s) $(paste -sd, - <<<"$m_ports") as any user, root and $((m_n-1)) login account(s)): $matches"
    fi
  fi

  kex=$(sget kexalgorithms); ciph=$(sget ciphers); macs=$(sget macs)
  weak=""
  for a in diffie-hellman-group1-sha1 diffie-hellman-group14-sha1 diffie-hellman-group-exchange-sha1; do
    [[ ",$kex," == *",$a,"* ]] && weak+="$a "
  done
  for a in ${ciph//,/ }; do [[ "$a" == *cbc* || "$a" == 3des* || "$a" == arcfour* ]] && weak+="$a "; done
  for a in ${macs//,/ }; do [[ "$a" == hmac-md5* ]] && weak+="$a "; done
  # What OpenSSH offers by default and ssh-audit flags: NIST curves, small or negotiated DH
  # groups, SHA-1 and 64-bit-tag MACs, encrypt-and-MAC (non-etm) MACs, RSA/ECDSA host keys.
  # The skill's default level is hardened, so this is a WARN that points at the fix.
  soft=""
  for a in ${kex//,/ }; do
    [[ "$a" == ecdh-sha2-nistp* || "$a" == *group-exchange* || "$a" == diffie-hellman-group14-sha256 ]] && soft+="$a "
  done
  for a in ${macs//,/ }; do
    [[ "$a" == hmac-md5* ]] && continue
    [[ "$a" == *sha1* || "$a" == umac-64* || "$a" != *-etm@openssh.com ]] && soft+="$a "
  done
  for a in $(sall hostkey); do
    case "${a##*/}" in *_rsa_key|*_ecdsa_key) soft+="${a##*/} " ;; esac
  done
  if [[ -n "$weak" ]]; then
    warn ssh.crypto "weak algorithms enabled: $weak"
  elif [[ -n "$soft" ]]; then
    read -ra soft_l <<<"$soft"
    soft_more=""; (( ${#soft_l[@]} > 6 )) && soft_more=" and $(( ${#soft_l[@]} - 6 )) more"
    warn ssh.crypto "OpenSSH default algorithm set: ${soft_l[*]:0:6}$soft_more. ssh-audit flags these; the hardened level restricts them. Apply the 'Hardened crypto' drop-in from references/ssh.md (01-vps-forge-crypto.conf)"
  else
    pass ssh.crypto "modern algorithms only (kex: ${kex%%,*}…)"
  fi

  hk=$(sall hostkey | xargs -r -n1 basename 2>/dev/null | paste -sd, -)
  info ssh.hostkeys "active host keys: ${hk:-?}"
  [[ -e /etc/ssh/ssh_host_dsa_key ]] && warn ssh.dsa "DSA host key present (obsolete)"
fi

# --------------------------------------------------------------- accounts ---
section accounts
uid0=$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | paste -sd, -)
if [[ -n "$uid0" ]]; then fail accounts.uid0 "UID 0 accounts besides root: $uid0"
else pass accounts.uid0 "only root has UID 0"; fi

shells=$(awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}' /etc/passwd | paste -sd, -)
info accounts.login_shells "accounts with a login shell: ${shells:-none}"

if need_root accounts.passwords "reading /etc/shadow"; then
  empty=$(awk -F: '$2==""{print $1}' /etc/shadow | paste -sd, -)
  if [[ -n "$empty" ]]; then fail accounts.passwords "accounts with EMPTY password: $empty"
  else pass accounts.passwords "no empty passwords"; fi
  rootpw=$(awk -F: '$1=="root"{print substr($2,1,1)}' /etc/shadow)
  if [[ "$rootpw" == '$' ]]; then info accounts.root_password "root has a password (OK for console access; keep it strong and offline)"
  else info accounts.root_password "root password locked/unset"; fi
fi

sudoers=$(getent group sudo 2>/dev/null | cut -d: -f4)
info accounts.sudo "sudo group: ${sudoers:-empty}"
# The skill hands a generated sudo password over in this file; it must not outlive the hand-off.
sudo_pw=$(find /home /root -maxdepth 2 -name SUDO-PASSWORD -type f 2>/dev/null | head -n 5 | paste -sd, -)
[[ -n "$sudo_pw" ]] && warn accounts.sudo_password_file "leftover sudo password file: $(untrusted "$sudo_pw" 200). Delete it once the password is stored elsewhere"
if (( IS_ROOT )); then
  nopw=$(grep -rlsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | paste -sd, -)
  [[ -n "$nopw" ]] && info accounts.nopasswd "NOPASSWD sudo rules in: $nopw"
  [[ -e /etc/sudoers.d/90-vps-forge-temp ]] && warn accounts.temp_sudo "temporary sudo grant /etc/sudoers.d/90-vps-forge-temp still present"
fi

if (( IS_ROOT )); then
  akfile=$(sget authorizedkeysfile); [[ -z "$akfile" ]] && akfile=".ssh/authorized_keys .ssh/authorized_keys2"
  rootlogin=$(sget permitrootlogin)
  # Every account, whatever its UID or shell: a key planted for postgres (uid 999, /bin/bash)
  # logs in, and with nologin it still opens tunnels (ssh -N).
  while IFS=: read -r user _ uid _ _ home shell; do
    [[ -n "$home" && -d "$home" ]] || continue
    for rel in $akfile; do
      rel=${rel//%h/$home}; rel=${rel//%u/$user}; rel=${rel//%%/%}
      [[ "$rel" == /* ]] && f="$rel" || f="$home/$rel"
      [[ -s "$f" ]] || continue
      n=$(grep -cvE '^\s*(#|$)' "$f")
      fps=""
      if have ssh-keygen; then
        fps=$(ssh-keygen -lf "$f" 2>/dev/null | awk '{c=""; for(i=3;i<NF;i++) c=c (c?" ":"") $i; gsub(/[^ -~]/, "?", c); printf "%s %s %s\n", $NF, substr($2,1,20) "…", substr(c,1,60)}' | head -n 6 | join_lines)
      fi
      msg="$user: $n key(s) in $f${fps:+ → $fps}"
      if [[ "$user" == "root" && "$rootlogin" == "no" ]]; then msg+=" (unused while root login is off)"; fi
      [[ "$shell" =~ (nologin|false)$ ]] && msg+=" (account has no login shell; tunnels still work unless forwarding is off)"
      (( uid > 0 && uid < 1000 )) && msg+=" (system account, uid $uid)"
      info accounts.keys "$msg"
      # The checks sshd's StrictModes makes on the key file and every directory up to the home
      # directory: owned by the user or root, and not writable by others. Debian's OpenSSH also
      # accepts group-writable when the group has the owner as its only member.
      kp_bad=""; p=$f
      while :; do
        if read -r kp_o kp_m kp_g < <(stat -L -c '%u %a %g' "$p" 2>/dev/null); then
          if [[ "$kp_o" != 0 && "$kp_o" != "$uid" ]]; then
            kp_bad+="$p is owned by $(id -nu "$kp_o" 2>/dev/null || echo "uid $kp_o"); "
          elif (( 8#$kp_m & 8#002 )); then
            kp_bad+="$p is world-writable; "
          elif (( 8#$kp_m & 8#020 )); then
            kp_mem=$( { getent passwd | awk -F: -v g="$kp_g" '$4==g{print $1}'; getent group "$kp_g" | cut -d: -f4 | tr ',' '\n'; } | sed '/^$/d' | sort -u | paste -sd' ' -)
            [[ "$kp_mem" == "$user" ]] || kp_bad+="$p is group-writable (group $(getent group "$kp_g" | cut -d: -f1)); "
          fi
        fi
        [[ "$p" == "$home" || "$p" == / || "$p" == . ]] && break
        p=$(dirname "$p")
      done
      if [[ -n "$kp_bad" ]]; then
        if [[ "$(sget strictmodes)" == no ]]; then
          warn accounts.keys_perm "${kp_bad%; }: other users can add keys for $user (StrictModes is off, so sshd accepts the file)"
        else
          warn accounts.keys_perm "key login for $user is refused (StrictModes): ${kp_bad%; }. Fix with chown $user and chmod go-w"
        fi
      fi
    done
  done < /etc/passwd
else
  skip accounts.keys "needs root: reading authorized_keys of all users"
fi

# --------------------------------------------------------------- firewall ---
section firewall
FW_ACTIVE=0; CF_SYNC=0
# Public IPv6: a global address outside fc00::/7 (ULA is not reachable from the internet).
HAS_V6=0
ip -6 addr show scope global 2>/dev/null | awk '$1=="inet6"{print $2}' | grep -qviE '^f[cd]' && HAS_V6=1
# Input base chains per nft family that end in drop: policy drop, or a last rule that is a bare
# drop/reject (OCI images ship policy accept + a final reject). "inet" covers both families.
# iptables-nft's chains (table filter, chain INPUT) are tagged ":ipt", native nftables ":nft".
nft_deny() {
  nft list ruleset 2>/dev/null | awk '
    /^table /{fam=$2; tbl=$3; next}
    /^[[:space:]]*chain [^ ]+ \{/{inch=1; inp=0; pol=0; last=""; ipt=(tbl=="filter" && $2=="INPUT"); next}
    !inch {next}
    /^[[:space:]]*#/{next}
    /type filter hook input/{inp=1; if ($0 ~ /policy drop/) pol=1; next}
    /^[[:space:]]*\}/{ if (inp && (pol || last ~ /^(drop|reject( with .*)?)$/)) print fam (ipt ? ":ipt" : ":nft"); inch=0; next}
    NF{ r=$0; gsub(/counter( packets [0-9]+ bytes [0-9]+)?/, "", r); sub(/[[:space:]]*comment ".*"$/, "", r)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", r); gsub(/[[:space:]]+/, " ", r); last=r }'
}
ipt_deny() { # iptables|ip6tables -> 0 when INPUT ends in DROP/REJECT
  local out
  have "$1" && out=$("$1" -S INPUT 2>/dev/null) || return 1
  grep -qE '^-P INPUT (DROP|REJECT)' <<<"$out" && return 0
  grep '^-A INPUT ' <<<"$out" | tail -n 1 | sed -E 's/ -m comment --comment ("[^"]*"|[^ ]+)//' | grep -qE '^-A INPUT -j (DROP|REJECT)( --reject-with [^ ]+)?$'
}
if have ufw && (( IS_ROOT )); then
  ufws=$(ufw status verbose 2>/dev/null || true)
  if grep -q '^Status: active' <<<"$ufws"; then
    FW_ACTIVE=1
    grep -q '# cf-sync' <<<"$ufws" && CF_SYNC=1
    # A temporary rule for the agent's own IP that should have gone at hand-off.
    agent_rules=$(grep -i '# agent session' <<<"$ufws" | sed -E 's/[[:space:]]{2,}/ /g' | head -n 3 | join_lines)
    [[ -n "$agent_rules" ]] && warn firewall.agent_ip "ufw rules for a temporary agent session are still there: $(untrusted "$agent_rules" 200). Delete them (ufw status numbered, ufw delete N)"
    if grep -qE '^Default: (deny|reject) \(incoming\)' <<<"$ufws"; then
      pass firewall.host "ufw active, default deny incoming"
    else
      fail firewall.host "ufw active but incoming default is not deny: $(grep '^Default:' <<<"$ufws")"
    fi
    rules=$(ufw status 2>/dev/null | awk 'NR>4 && NF' | grep -v '(v6)' | sed -E 's/[[:space:]]{2,}/ /g' | head -n 15 | join_lines)
    info firewall.rules "${rules:-no rules}"
    if (( HAS_V6 )); then
      if grep -qiE '^IPV6=yes' /etc/default/ufw 2>/dev/null; then pass firewall.ipv6 "ufw covers IPv6"
      else fail firewall.ipv6 "server has public IPv6 but ufw IPV6 is not 'yes': everything is open on v6"; fi
    fi
    if (( HAVE_SYSTEMD )); then
      if ! grep -qE '^[[:space:]]*ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
        warn firewall.boot "ufw is active now but ENABLED=no in /etc/ufw/ufw.conf: the firewall is gone after a reboot. Run 'ufw enable'"
      elif ! unit_enabled ufw.service; then
        warn firewall.boot "ufw.service is not enabled: the firewall is gone after a reboot. systemctl enable ufw"
      else
        pass firewall.boot "ufw starts at boot"
      fi
    fi
  fi
fi
if (( ! FW_ACTIVE )) && (( IS_ROOT )); then
  # Collect deny-by-default per address family from every source, then give one verdict.
  v4=""; v6=""
  fams=" $(have nft && nft_deny | sort -u | paste -sd' ' -) "
  for f in $fams; do
    case "${f%%:*}" in
      inet) v4+="${v4:+,}${f#*:}"; v6+="${v6:+,}${f#*:}" ;;
      ip) v4+="${v4:+,}${f#*:}" ;;
      ip6) v6+="${v6:+,}${f#*:}" ;;
    esac
  done
  [[ -z "$v4" ]] && ipt_deny iptables && v4=ipt
  [[ -z "$v6" ]] && (( HAS_V6 )) && ipt_deny ip6tables && v6=ipt
  fw_src=",$v4,$v6,"
  fw_desc=""
  [[ "$fw_src" == *nft* ]] && fw_desc+="nftables"
  [[ "$fw_src" == *ipt* ]] && fw_desc+="${fw_desc:+ + }iptables"
  if [[ -n "$v4" ]]; then
    FW_ACTIVE=1
    if [[ -n "$v6" ]]; then pass firewall.host "$fw_desc: IPv4 and IPv6 input default to deny"
    else pass firewall.host "$fw_desc: IPv4 input defaults to deny"; fi
    if (( HAS_V6 )); then
      if [[ -n "$v6" ]]; then pass firewall.ipv6 "IPv6 input defaults to deny"
      else fail firewall.ipv6 "IPv6 open: the server has public IPv6, but only IPv4 input defaults to deny. Use an inet table (nftables) or ip6tables rules"; fi
    fi
    if (( HAVE_SYSTEMD )); then
      # Rules in the kernel are lost on reboot unless a service loads them again.
      fw_boot=""
      if [[ "$fw_src" == *nft* ]] && ! unit_enabled nftables.service && ! unit_enabled firewalld.service; then
        fw_boot+="nftables.service is not enabled (check that /etc/nftables.conf holds these rules, then systemctl enable nftables); "
      fi
      if [[ "$fw_src" == *ipt* ]] && ! unit_enabled netfilter-persistent.service && ! unit_enabled iptables.service && ! unit_enabled firewalld.service \
         && ! grep -lqs 'iptables-restore' /etc/network/if-pre-up.d/* /etc/network/if-up.d/* /etc/rc.local /etc/systemd/system/*.service 2>/dev/null; then
        fw_boot+="nothing restores the iptables rules (netfilter-persistent is not enabled); "
      fi
      if [[ -n "$fw_boot" ]]; then warn firewall.boot "the firewall is gone after a reboot: ${fw_boot%; }"
      else pass firewall.boot "firewall rules are restored at boot"; fi
    fi
  else
    fail firewall.host "no active host firewall found (ufw/nftables/iptables)"
  fi
elif (( ! IS_ROOT )); then
  skip firewall.host "needs root: reading firewall state"
fi

# --------------------------------------------------------------- exposure ---
section exposure
if have ss; then
  declare -A seen=()
  exposed=0
  WG_PORTS=""
  have wg && WG_PORTS=$(wg show all listen-port 2>/dev/null | awk '{print $2}' | paste -sd' ' -)
  while read -r proto _ _ _ local _ proc; do
    addr=${local%:*}; port=${local##*:}
    addr=${addr#[}; addr=${addr%]}; addr=${addr%%%*}
    case "$addr" in
      127.*|::1|localhost) continue ;;
    esac
    name=$(sed -nE 's/.*\(\("([^"]+)".*/\1/p' <<<"$proc")
    [[ -z "$name" ]] && name="?"
    name=$(untrusted "$name" 40)
    # systemd holding a port of ssh.socket is SSH waiting for a connection, not a stray service.
    [[ "$proto" == tcp && "$name" == systemd && " $(paste -sd' ' - <<<"$SSH_SOCK_PORTS") " == *" $port "* ]] && name=ssh.socket
    key="$proto/$port/$name"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    case "$addr" in
      0.0.0.0|::|'*') scope="all interfaces" ;;
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fe80*|fd*) scope="private $addr" ;;
      *) scope="$addr" ;;
    esac
    if [[ "$proto" == udp && ( "$port" == 68 || "$port" == 546 ) ]]; then continue; fi
    # kernel WireGuard has no owning process in ss output
    if [[ "$proto" == udp && "$name" == "?" && " $WG_PORTS " == *" $port "* ]]; then name=wireguard; fi
    case "$name" in
      sshd|sshd-session|ssh.socket|caddy|nginx|apache2|haproxy|traefik|tailscaled|cloudflared|wireguard)
        info exposure.listen "$proto/$port $name on $scope (expected)" ;;
      docker-proxy)
        info exposure.listen "$proto/$port docker-proxy on $scope (see docker check)" ;;
      *)
        if [[ "$scope" == private* ]]; then
          info exposure.listen "$proto/$port $name on $scope"
        else
          exposed=$((exposed+1))
          warn exposure.listen "$proto/$port $name listens on $scope: bind it to 127.0.0.1, or confirm the firewall blocks it and it's intended"
        fi ;;
    esac
  done < <(ss -H -tulpn 2>/dev/null | awk '{print $1, $2, $3, $4, $5, $6, $7}')
  (( exposed == 0 )) && pass exposure.summary "no unexpected services on public interfaces"
  (( IS_ROOT )) || info exposure.note "run as root to see process names"
fi

if have docker && docker info >/dev/null 2>&1; then
  dock_flag=0; dock_web=0
  # Published ports skip ufw's INPUT chain; the DOCKER-USER chain is where they can be filtered.
  # Anything beyond Docker's lone RETURN counts as filtering (per family, iptables or nft).
  du_rules() { # family: 4|6
    local ipt=iptables fam=ip out
    [[ "$1" == 6 ]] && ipt=ip6tables fam=ip6
    if have "$ipt" && out=$("$ipt" -S DOCKER-USER 2>/dev/null); then
      grep '^-A DOCKER-USER ' <<<"$out" | grep -vx -- '-A DOCKER-USER -j RETURN'
    elif have nft && out=$(nft list chain "$fam" filter DOCKER-USER 2>/dev/null); then
      sed '1,/chain DOCKER-USER/d' <<<"$out" | grep -vE '^[[:space:]]*(\}|$|(counter packets [0-9]+ bytes [0-9]+ )?return$)'
    fi
  }
  DU4=0; DU6=0
  (( IS_ROOT )) && [[ -n "$(du_rules 4)" ]] && DU4=1
  (( IS_ROOT )) && [[ -n "$(du_rules 6)" ]] && DU6=1
  # Every published mapping "HostIp:HostPort->Port/proto"; any non-loopback host IP bypasses ufw.
  while IFS='|' read -r cname cports; do
    [[ -n "$cname" ]] || continue
    cname=$(untrusted "$cname" 60)
    all=""; public=""; private=""; web=""; filtered=""; cf_open=""
    IFS=',' read -ra maps <<<"$cports"
    for m in "${maps[@]}"; do
      m=${m# }
      [[ "$m" == *"->"* ]] || continue
      hip=${m%%->*}; hport=${hip##*:}; hip=${hip%:*}; hip=${hip#\[}; hip=${hip%\]}
      proto=${m##*/}
      case "$hip" in 127.*|::1) continue ;; esac
      # A reverse proxy is meant to be reachable: HTTP, HTTPS and HTTP/3 (443/udp).
      if [[ "$hport/$proto" == 80/tcp || "$hport/$proto" == 443/tcp || "$hport/$proto" == 443/udp ]]; then
        web+="$m,"
        # ufw's Cloudflare allowlist (cf-sync) never sees these packets; DOCKER-USER does.
        if (( CF_SYNC )) && [[ "$hip" == 0.0.0.0 || "$hip" == :: || -z "$hip" ]] \
           && [[ ( "$hip" == *:* && DU6 -eq 0 ) || ( "$hip" != *:* && DU4 -eq 0 ) ]]; then cf_open+="$m,"; fi
        continue
      fi
      case "$hip" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fe80*|fd*) private+="$m,"; continue ;;
      esac
      if [[ ( "$hip" == *:* && DU6 -eq 1 ) || ( "$hip" != *:* && DU4 -eq 1 ) ]]; then filtered+="$m,"; continue; fi
      case "$hip" in
        0.0.0.0|::|'') all+="$m," ;;
        *) public+="$m," ;;
      esac
    done
    if [[ -n "$web" ]]; then dock_web=1
      info exposure.docker "container '$cname' publishes ${web%,} (web entry point, e.g. a reverse proxy); Docker bypasses ufw, so these are open to everyone whatever ufw says"
    fi
    if [[ -n "$cf_open" ]]; then
      warn exposure.cloudflare "container '$cname' publishes ${cf_open%,} on all interfaces: the Cloudflare allowlist is in ufw (cf-sync), which Docker bypasses, so anyone can reach the proxy directly and skip Cloudflare. Allow only Cloudflare ranges to 80/443 in DOCKER-USER"
    fi
    if [[ -n "$filtered" ]]; then dock_flag=1
      warn exposure.docker "container '$cname' publishes ${filtered%,} publicly; Docker bypasses ufw, but DOCKER-USER has filtering rules: verify they restrict these ports (iptables -S DOCKER-USER)"
    fi
    if [[ -n "$all" ]]; then dock_flag=1
      fail exposure.docker "container '$cname' publishes ${all%,} on all interfaces; Docker bypasses ufw. Bind to 127.0.0.1 or filter in DOCKER-USER"
    fi
    if [[ -n "$public" ]]; then dock_flag=1
      fail exposure.docker "container '$cname' publishes ${public%,} on a public address; Docker bypasses ufw. Bind to 127.0.0.1 or filter in DOCKER-USER"
    fi
    if [[ -n "$private" ]]; then dock_flag=1
      warn exposure.docker "container '$cname' publishes ${private%,} on a private address; Docker bypasses ufw, so everyone on that network reaches it"
    fi
  done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null)
  # Host-network containers have no published ports; their listeners sit directly on the host.
  while IFS='|' read -r cname cmode; do
    [[ "$cmode" == host ]] || continue
    dock_flag=1
    warn exposure.docker "container '$(untrusted "${cname#/}" 60)' uses network_mode host: every port it opens is on the host's interfaces (see exposure.listen). Prefer a bridge network with ports bound to 127.0.0.1"
  done < <(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}}|{{.HostConfig.NetworkMode}}' 2>/dev/null)
  (( dock_flag )) || pass exposure.docker "no container ports published beyond loopback$( (( dock_web )) && echo ' and web ports 80/443'), no host-network containers"
  info exposure.docker_count "$(docker ps -q 2>/dev/null | wc -l) running container(s)"
fi

# ----------------------------------------------------------- intrusion ------
section intrusion
f2b_port_num() { # service name or number -> number; fails when unknown
  local n=$1
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    n=$(getent services "$1/tcp" 2>/dev/null | awk '{split($2, a, "/"); print a[1]; exit}')
    [[ -z "$n" && "$1" == ssh ]] && n=22 # minimal images ship without /etc/services
  fi
  [[ -n "$n" ]] && echo "$n"
}
f2b_port_covers() { # spec port -> 0 covered, 1 not covered, 2 unknown name in spec
  local item lo hi rc=1
  local -a items
  IFS=',' read -ra items <<<"$1"
  for item in "${items[@]}"; do
    item=${item//[[:space:]]/}
    [[ -n "$item" ]] || continue
    [[ "$item" == all || "$item" == any ]] && return 0
    if [[ "$item" == *:* ]]; then lo=${item%%:*}; hi=${item#*:}
    elif [[ "$item" =~ ^[0-9]+-[0-9]+$ ]]; then lo=${item%-*}; hi=${item#*-}
    else lo=$item; hi=$item; fi
    if ! lo=$(f2b_port_num "$lo") || ! hi=$(f2b_port_num "$hi"); then rc=2; continue; fi
    (( $2 >= lo && $2 <= hi )) && return 0
  done
  return "$rc"
}
agent_f2b=$(grep -lsi 'agent session' /etc/fail2ban/jail.local /etc/fail2ban/jail.d/* 2>/dev/null | paste -sd, -)
[[ -n "$agent_f2b" ]] && warn intrusion.agent_ip "fail2ban config still has an entry for a temporary agent session ($(untrusted "$agent_f2b" 200)): remove that ignoreip address and reload fail2ban"
if systemctl is-active --quiet crowdsec 2>/dev/null; then
  pass intrusion.ips "CrowdSec running"
elif systemctl is-active --quiet fail2ban 2>/dev/null; then
  if (( IS_ROOT )) && have fail2ban-client; then
    st=$(fail2ban-client status sshd 2>/dev/null || true)
    if [[ -n "$st" ]]; then
      tf=$(awk -F: '/Total failed/{gsub(/[[:space:]]/,"",$2); print $2}' <<<"$st")
      cb=$(awk -F: '/Currently banned/{gsub(/[[:space:]]/,"",$2); print $2}' <<<"$st")
      tb=$(awk -F: '/Total banned/{gsub(/[[:space:]]/,"",$2); print $2}' <<<"$st")
      # A jail whose actions block another port than sshd's (Port changed, jail left at "ssh")
      # counts and "bans" attackers who keep hammering the real port. Read the running jail.
      f2b_all=0; f2b_specs=""; f2b_missing=""
      ssh_ports=$(tr ' ' '\n' <<<"$SSH_PORTS" | sed '/^$/d')
      if [[ -n "$ssh_ports" ]]; then
        while read -r a; do
          [[ -n "$a" ]] || continue
          if [[ "$a" == *allports* ]]; then f2b_all=1; break; fi
          if p=$(fail2ban-client get sshd action "$a" port 2>/dev/null) && [[ -n "$p" ]]; then
            # Port-scoped rules carry the port (--dports ssh, dport { 'ssh' }); an all-ports
            # variant under another name (nftables[type=allports]) installs a rule without it.
            start=$(fail2ban-client get sshd action "$a" actionstart 2>/dev/null) || start=""
            if [[ " $start " != *[!A-Za-z0-9_-]"$p"[!A-Za-z0-9_-]* ]] && grep -qE 'iptables|nft |firewall-cmd|ipset|shorewall' <<<"$start"; then
              f2b_all=1; break
            fi
            f2b_specs+="${f2b_specs:+|}$p"
          else
            # No port option: a whole-address ban (ufw, route) or a notification (sendmail).
            ban=$(fail2ban-client get sshd action "$a" actionban 2>/dev/null) || ban=""
            if grep -qE '(^|[[:space:]])(ufw|ip route|iptables|ip6tables|nft|firewall-cmd|ipset)[[:space:]]' <<<"$ban"; then f2b_all=1; break; fi
          fi
        done < <(fail2ban-client get sshd actions 2>/dev/null | tail -n +2 | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if (( ! f2b_all )) && [[ -n "$f2b_specs" ]]; then
          for sp in $ssh_ports; do
            hit=1
            IFS='|' read -ra f2b_list <<<"$f2b_specs"
            for spec in "${f2b_list[@]}"; do
              f2b_port_covers "$spec" "$sp"; r=$?
              (( r < hit )) && hit=$r
            done
            (( hit == 1 )) && f2b_missing+="${f2b_missing:+,}$sp"
          done
        fi
      fi
      if [[ -n "$f2b_missing" ]]; then
        # WARN, like having no IPS at all: that is exactly what this amounts to.
        warn intrusion.ips "fail2ban sshd jail blocks port(s) ${f2b_specs//|/; } but sshd listens on $(paste -sd, - <<<"$ssh_ports"): bans never reach SSH, so the jail protects nothing while still counting bans (total failed: ${tf:-?}, total banned: ${tb:-?}). Set 'port = $f2b_missing' in the [sshd] jail, or use an allports banaction"
      else
        pass intrusion.ips "fail2ban sshd jail active (total failed: ${tf:-?}, banned now: ${cb:-?}, total banned: ${tb:-?})"
      fi
      # Only loopback ignored: the admin's own failed test logins ban the admin, and the
      # deadman does not undo fail2ban bans.
      if ig=$(fail2ban-client get sshd ignoreip 2>/dev/null); then
        ig_other=$(grep -E '^[|`]-' <<<"$ig" | sed -E 's/^[|`]-[[:space:]]*//' | grep -vE '^(127\.[0-9./]*|::1(/128)?|localhost)$')
        if [[ -z "$ig_other" ]]; then
          warn intrusion.ignoreip "fail2ban's sshd jail ignores only loopback: a few failed test logins from your own address ban you. Add your admin IP to ignoreip in /etc/fail2ban/jail.d/vps-forge.local"
        fi
      fi
    else
      warn intrusion.ips "fail2ban running but no sshd jail"
    fi
  else
    pass intrusion.ips "fail2ban running"
  fi
else
  warn intrusion.ips "no fail2ban or CrowdSec running"
fi

# ----------------------------------------------------------------- kernel ---
section kernel
declare -a want=(
  "net.ipv4.tcp_syncookies=1"
  "net.ipv4.conf.all.rp_filter=1|2"
  "net.ipv4.conf.all.accept_redirects=0"
  "net.ipv4.conf.default.accept_redirects=0"
  "net.ipv6.conf.all.accept_redirects=0"
  "net.ipv4.conf.all.send_redirects=0"
  "net.ipv4.conf.all.accept_source_route=0"
  "net.ipv4.icmp_echo_ignore_broadcasts=1"
  "kernel.kptr_restrict=1|2"
  "kernel.dmesg_restrict=1"
  "kernel.randomize_va_space=2"
  "kernel.yama.ptrace_scope=1|2|3"
  "fs.protected_hardlinks=1"
  "fs.protected_symlinks=1"
  "fs.protected_regular=1|2"
  "fs.protected_fifos=1|2"
  "fs.suid_dumpable=0"
)
bad=""
for w in "${want[@]}"; do
  k=${w%%=*}; ok=${w#*=}
  # kernel.* and fs.* belong to the host kernel in a container; net.* lives in the netns.
  [[ -n "$CONTAINER" && "$k" != net.* ]] && continue
  f="/proc/sys/${k//./\/}"
  [[ -r "$f" ]] || continue
  cur=$(tr -d '[:space:]' < "$f")
  [[ "|$ok|" == *"|$cur|"* ]] || bad+="$k=$cur (want ${ok//|/ or }); "
done
# conf.all is not the whole story: IPv4 accepts or sends redirects when either "all" or the
# interface says so, and IPv6 only looks at the interface. Interfaces that exist before
# systemd-sysctl runs keep the kernel default, which conf.default doesn't change.
for f in /proc/sys/net/ipv4/conf/*/accept_redirects /proc/sys/net/ipv4/conf/*/send_redirects /proc/sys/net/ipv4/conf/*/accept_source_route \
         /proc/sys/net/ipv6/conf/*/accept_redirects /proc/sys/net/ipv6/conf/*/accept_source_route; do
  ifc=${f%/*}; ifc=${ifc##*/}
  case "$ifc" in all|default|lo|docker*|veth*|br-*) continue ;; esac
  [[ -r "$f" ]] || continue
  cur=$(tr -d '[:space:]' < "$f")
  k=${f#/proc/sys/net/}; fam=${k%%/*}
  [[ "$cur" == 0 ]] || bad+="net.$fam.conf.$(untrusted "$ifc" 20).${f##*/}=$cur (want 0); "
done
if [[ -z "$bad" ]]; then pass kernel.sysctl "hardening sysctls set${CONTAINER:+ (net.* only)}"
else warn kernel.sysctl "${bad%; }"; fi
[[ -n "$CONTAINER" ]] && skip kernel.host "kernel.* and fs.* sysctls are host-controlled in a $CONTAINER container"
cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "?")
info kernel.congestion "TCP congestion control: $cc"
if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" == "Y" ]]; then
  pass kernel.apparmor "AppArmor enabled"
elif [[ -n "$CONTAINER" ]]; then
  skip kernel.apparmor "host-controlled in a $CONTAINER container"
else
  warn kernel.apparmor "AppArmor not enabled"
fi

# ------------------------------------------------------------------- time ---
section time
if have timedatectl; then
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  case "$sync" in
    yes) pass time.sync "clock synchronized (timezone ${tz:-?})" ;;
    no) warn time.sync "clock NOT synchronized (timezone ${tz:-?})" ;;
    *) skip time.sync "time sync state unavailable" ;;
  esac
fi

# -------------------------------------------------------------- resources ---
section resources
while read -r fs _ _ _ pct mnt; do
  p=${pct%\%}; [[ "$p" =~ ^[0-9]+$ ]] || continue
  if (( p >= 95 )); then fail resources.disk "$mnt is ${p}% full ($fs)"
  elif (( p >= 85 )); then warn resources.disk "$mnt is ${p}% full ($fs)"; fi
done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1')
while read -r _ _ _ _ pct mnt; do
  p=${pct%\%}; [[ "$p" =~ ^[0-9]+$ ]] || continue
  (( p >= 90 )) && warn resources.inodes "$mnt inodes ${p}% used"
done < <(df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1')
grep -q '^resources.disk$' < <(printf '%s\n' "${R_ID[@]}") || pass resources.disk "all filesystems below 85%"

mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
info resources.memory "RAM $((mem_kb/1024)) MiB, swap $((swap_kb/1024)) MiB"
if (( mem_kb <= 2200000 && swap_kb == 0 )) && [[ -n "$CONTAINER" ]]; then
  skip resources.swap "≤2 GB RAM and no swap, but swap is host-controlled in a $CONTAINER container"
elif (( mem_kb <= 2200000 && swap_kb == 0 )); then
  warn resources.swap "≤2 GB RAM and no swap: the OOM killer will take down services under load"
fi

if [[ -d /var/log/journal ]]; then pass resources.journal_persistent "journal is persistent"
else warn resources.journal_persistent "journal is volatile: logs are lost on reboot"; fi
if grep -rqsE '^\s*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null; then
  pass resources.journal_cap "journald size capped"
else
  info resources.journal_cap "journald size not capped explicitly (default 10% of the filesystem)"
fi
if have journalctl; then
  ju=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -n 1)
  [[ -n "$ju" ]] && info resources.journal_size "journal uses $ju"
fi

# --------------------------------------------------------------- services ---
section services
if have systemctl && systemctl list-units --no-legend >/dev/null 2>&1; then
  failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, -)
  if [[ -n "$failed" ]]; then warn services.failed "failed units: $(untrusted "$failed" 300)"
  else pass services.failed "no failed systemd units"; fi
  if systemctl is-active --quiet vps-forge-deadman.timer 2>/dev/null; then
    warn services.deadman "vps-forge deadman is still ARMED: it will roll back SSH/firewall config. Disarm when done"
  fi
  if [[ -x /usr/local/bin/vps-notify ]]; then
    if systemctl is-active --quiet vps-forge-health.timer 2>/dev/null; then pass services.alerts "vps-forge alerts installed, health timer active"
    else warn services.alerts "vps-notify installed but health timer inactive"; fi
  else
    info services.alerts "no vps-forge alerting installed"
  fi
else
  skip services.failed "systemd not available"
fi

# ---------------------------------------------------------------- backups ---
section backups
bk=""
if (( HAVE_SYSTEMD )); then
  # Only timers that are scheduled (NEXT is a date, not "-" or "n/a") and enabled, so they
  # survive a reboot. dpkg-db-backup, apt-daily and e2scrub ship with the OS and back up no data.
  while read -r t; do
    case "$t" in dpkg-db-backup.timer|apt-daily*|e2scrub*) continue ;; esac
    unit_enabled "$t" && bk+="${bk:+,}$(untrusted "$t" 60)"
  done < <(systemctl list-timers --no-legend 2>/dev/null | awk '$1!="-" && $1!="n/a"' \
    | grep -oiE '[[:alnum:]@._-]*(restic|borg|backup|kopia|rsnapshot|duplicity)[[:alnum:]@._-]*\.timer' | sort -u)
fi
if [[ -z "$bk" ]]; then
  bk=$(grep -lsiE '^[[:space:]]*[^#[:space:]].*(restic|borg|rsnapshot|duplicity|kopia|pg_dump|mysqldump)' /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* 2>/dev/null | paste -sd, -)
  bk=$(untrusted "$bk" 200)
fi
if [[ -n "$bk" ]]; then
  pass backups.job "backup job found: $bk"
  if (( HAVE_SYSTEMD )) && systemctl cat vps-forge-backup.service >/dev/null 2>&1; then
    res=$(systemctl show -p Result --value vps-forge-backup.service 2>/dev/null)
    last=$(systemctl show -p ExecMainExitTimestamp --value vps-forge-backup.service 2>/dev/null)
    if [[ "$res" == "success" && -n "$last" ]]; then info backups.last "last vps-forge backup: $last"
    elif [[ -n "$last" ]]; then warn backups.last "last vps-forge backup result: ${res:-?} at $last"
    else info backups.last "vps-forge backup has not run yet"; fi
  fi
else
  warn backups.job "no backup job found (provider snapshots can't be detected from inside the VM)"
fi

# ------------------------------------------------------------ changes ------
section changes
if [[ -d /etc/.git ]]; then
  pass changes.etckeeper "/etc is version-controlled ($( (git -C /etc rev-list --count HEAD 2>/dev/null || echo '?') ) commits)"
else
  info changes.etckeeper "/etc is not under version control (etckeeper)"
fi

# ------------------------------------------------------------- compromise ---
section compromise
if [[ -s /etc/ld.so.preload ]]; then
  fail compromise.preload "/etc/ld.so.preload is not empty: classic rootkit technique, investigate: $(untrusted "$(head -c 200 /etc/ld.so.preload)" 200)"
else
  pass compromise.preload "no ld.so.preload"
fi
# File names are chosen by whoever wrote them: NUL-separated, so a newline can't split one.
tmpx=""; tmpn=0
while IFS= read -r -d '' f; do
  [[ "$f" == */systemd-private-* ]] && continue
  tmpn=$((tmpn+1))
  (( tmpn <= 5 )) && tmpx+="${tmpx:+; }$(untrusted "$f")"
done < <(find /tmp /var/tmp /dev/shm -maxdepth 3 -type f -perm /111 -print0 2>/dev/null)
(( tmpn > 5 )) && tmpx+=" and $((tmpn-5)) more"
if [[ -n "$tmpx" ]]; then warn compromise.tmp_exec "executables in temp dirs: $tmpx"
else pass compromise.tmp_exec "no executables in /tmp, /var/tmp, /dev/shm"; fi
cronbad=$(grep -lsE '(curl|wget)[^#]*\|[[:space:]]*(ba|da|z)?sh|base64[[:space:]]+(-d|--decode)' /etc/crontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /var/spool/cron/crontabs/* 2>/dev/null | paste -sd, -)
if [[ -n "$cronbad" ]]; then warn compromise.cron "cron entries download-and-execute or decode base64: $(untrusted "$cronbad" 300)"
else pass compromise.cron "no download-and-execute cron entries"; fi
# Same pattern in locally installed systemd units, timers and drop-ins (package units under
# /lib are left out; symlinks in *.wants are not followed by grep -r).
unitbad=$(grep -rlsE '(curl|wget)[^#]*\|[[:space:]]*(ba|da|z)?sh|base64[[:space:]]+(-d|--decode)' /etc/systemd/system /etc/systemd/user /usr/local/lib/systemd /root/.config/systemd 2>/dev/null | head -n 10 | paste -sd, -)
if [[ -n "$unitbad" ]]; then warn compromise.systemd "systemd units download-and-execute or decode base64: $(untrusted "$unitbad" 400)"
else pass compromise.systemd "no download-and-execute systemd units"; fi
if (( IS_ROOT )); then
  deleted=""; deleted_tmp=""; deleted_memfd=""
  for exe in /proc/[0-9]*/exe; do
    t=$(readlink "$exe" 2>/dev/null) || continue
    [[ "$t" == *" (deleted)" ]] || continue
    t=${t% (deleted)}
    t=$(untrusted "$t" 80)
    case "$t" in
      /tmp/*|/var/tmp/*|/dev/shm/*) deleted_tmp+="$t " ;;
      /memfd:*) deleted_memfd+="$t " ;;
      *) deleted+="${t##*/} " ;;
    esac
  done
  if [[ -n "$deleted_tmp" ]]; then fail compromise.deleted_exe "processes running deleted binaries from temp/memfd: $deleted_tmp"; fi
  if [[ -n "$deleted_memfd" ]]; then
    warn compromise.memfd_exe "fileless (memfd) executables running: $deleted_memfd. Some runtimes do this legitimately; investigate if unknown"
  fi
  if [[ -n "$deleted" ]]; then
    info compromise.deleted_exe "processes running replaced binaries (normal after upgrades; restart them): $(tr ' ' '\n' <<<"$deleted" | sort -u | paste -sd' ' -)"
  fi
fi
# comm last: a process can name itself anything, spaces included.
hot=$(ps -eo pid=,pcpu=,comm= --sort=-pcpu 2>/dev/null | awk '$2>80{c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9.]+[[:space:]]/, "", c); printf "%s(%s) %s%%; ", c, $1, $2}')
[[ -n "$hot" ]] && info compromise.cpu "processes above 80% CPU right now: $(untrusted "$hot" 300)"

# ----------------------------------------------------------------- output ---
P=0 W=0 F=0 I=0 S=0
for s in "${R_STATUS[@]}"; do
  case "$s" in PASS) P=$((P+1));; WARN) W=$((W+1));; FAIL) F=$((F+1));; INFO) I=$((I+1));; SKIP) S=$((S+1));; esac
done
den=$(( 2*(P+W+F) ))
SCORE=0; (( den > 0 )) && SCORE=$(( (200*P + 100*W + den/2) / den ))

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/ }
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177')
  printf '"%s"' "$s"
}

if (( JSON )); then
  printf '{"tool":"vps-forge-audit","version":%s,"host":%s,"os":%s,"date":%s,"root":%s,"score":%d,' \
    "$(json_str "$VERSION")" "$(json_str "$(hostname)")" "$(json_str "$OS_PRETTY")" \
    "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$([[ $IS_ROOT -eq 1 ]] && echo true || echo false)" "$SCORE"
  printf '"counts":{"pass":%d,"warn":%d,"fail":%d,"info":%d,"skip":%d},"checks":[' "$P" "$W" "$F" "$I" "$S"
  for i in "${!R_ID[@]}"; do
    (( i > 0 )) && printf ','
    printf '{"section":%s,"id":%s,"status":%s,"message":%s}' \
      "$(json_str "${R_SECTION[$i]}")" "$(json_str "${R_ID[$i]}")" "$(json_str "${R_STATUS[$i]}")" "$(json_str "${R_MSG[$i]}")"
  done
  printf ']}\n'
else
  if (( COLOR )); then
    cP=$'\e[32m' cW=$'\e[33m' cF=$'\e[31;1m' cI=$'\e[36m' cS=$'\e[90m' cB=$'\e[1m' c0=$'\e[0m'
  else
    cP="" cW="" cF="" cI="" cS="" cB="" c0=""
  fi
  printf '%svps-forge audit %s%s · %s · %s · %s\n' "$cB" "$VERSION" "$c0" "$(clean "$(hostname)")" "$(clean "$OS_PRETTY")" "$(date -u +%Y-%m-%dT%H:%MZ)"
  (( IS_ROOT )) || printf '%s(not root: some checks skipped)%s\n' "$cW" "$c0"
  last=""
  for i in "${!R_ID[@]}"; do
    st=${R_STATUS[$i]}
    if (( QUIET )) && [[ "$st" == PASS || "$st" == INFO || "$st" == SKIP ]]; then continue; fi
    if [[ "${R_SECTION[$i]}" != "$last" ]]; then
      last=${R_SECTION[$i]}; printf '\n%s%s%s\n' "$cB" "${last^^}" "$c0"
    fi
    case "$st" in PASS) c=$cP;; WARN) c=$cW;; FAIL) c=$cF;; INFO) c=$cI;; *) c=$cS;; esac
    printf '  %s%-4s%s  %-28s %s\n' "$c" "$st" "$c0" "${R_ID[$i]}" "${R_MSG[$i]}"
  done
  printf '\n%sScore: %d/100%s   pass %d · warn %d · fail %d · info %d · skip %d\n' "$cB" "$SCORE" "$c0" "$P" "$W" "$F" "$I" "$S"
fi

(( F > 0 )) && exit 1
exit 0
