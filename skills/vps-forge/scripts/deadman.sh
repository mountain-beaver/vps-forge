#!/usr/bin/env bash
# vps-forge deadman: automatic rollback of SSH / firewall / sudo / PAM config unless disarmed.
#
#   vps-forge-deadman arm [MINUTES] [--ip ADDR]
#                                     snapshot config now, roll back in MINUTES (default 5). The
#                                     rollback also unbans ADDR in fail2ban (default: the SSH
#                                     client address of this session)
#   vps-forge-deadman extend MINUTES  still armed and need more time before the test: move the
#                                     rollback to MINUTES from now. Same snapshot; never use it to
#                                     keep a change whose test login failed
#   vps-forge-deadman disarm          the change works: cancel the rollback. Exits 3 (and prints
#                                     ROLLED BACK) if a rollback already ran since arm: then the
#                                     changes were NOT kept
#   vps-forge-deadman status          show timer and snapshots
#   vps-forge-deadman restore [DIR]   roll back now (to DIR, else the armed snapshot, else the latest)
#   vps-forge-deadman snapshot        take a snapshot without arming
#   vps-forge-deadman client-ip       print the address of this session's SSH client (works under
#                                     sudo); exits 1 outside an SSH session
#
# Typical use around a risky change:
#   vps-forge-deadman arm 5 → change sshd/ufw → test from a NEW connection → vps-forge-deadman disarm
# The test must bypass SSH multiplexing, or it reuses the old connection and proves nothing:
#   ssh -o ControlPath=none -o BatchMode=yes -p <port> <admin>@<host> 'sudo -n vps-forge-deadman disarm'
# (NOPASSWD sudo; for password sudo see references/ssh.md "Test and disarm")
# If the new connection fails, do nothing: the timer restores the snapshot, reloads ssh and
# restores the previous ufw state. Existing SSH sessions survive (ssh.service uses KillMode=process).
# The timer is runtime-only, so arm also enables vps-forge-deadman-boot.service: if the server
# reboots while armed, the rollback runs at boot instead.
#
# Install once (must be a file on disk, not piped):
#   install -m 755 deadman.sh /usr/local/sbin/vps-forge-deadman
# Part of vps-forge (MIT).

set -uo pipefail
# ufw status is translated on localized systems ("Status: aktiv"); the checks below
# grep for the English "Status: active".
export LC_ALL=C
umask 077

ROOT=${VPS_FORGE_ROOT:-/}          # test hook: operate on a fake root
SKIP_SERVICES=${VPS_FORGE_SKIP_SERVICES:-0}
STATE="${ROOT%/}/var/lib/vps-forge/deadman"
UNIT=vps-forge-deadman
BOOT_UNIT=vps-forge-deadman-boot.service
BOOT_FILE="${ROOT%/}/etc/systemd/system/$BOOT_UNIT"
BOOT_LINK="${ROOT%/}/etc/systemd/system/multi-user.target.wants/$BOOT_UNIT"
KEEP=10
# A path absent at snapshot time is removed (moved aside) by the rollback if it appeared since.
PATHS=(etc/ssh etc/default/ssh etc/ufw etc/default/ufw etc/nftables.conf etc/iptables
       etc/sudoers etc/sudoers.d etc/pam.d/sshd etc/pam.d/sudo etc/pam.d/common-auth
       etc/pam.d/common-account etc/pam.d/common-password etc/pam.d/common-session
       etc/pam.d/common-session-noninteractive etc/security/access.conf
       etc/systemd/system/ssh.socket etc/systemd/system/ssh.service
       etc/systemd/system/ssh.socket.d etc/systemd/system/ssh.service.d)
# Their `systemctl is-enabled` state is recorded at snapshot time and re-applied by the rollback.
UNITS=(ssh.service ssh.socket ufw.service nftables.service netfilter-persistent.service)

log() { echo "deadman: $*"; command -v logger >/dev/null 2>&1 && logger -t vps-forge-deadman -- "$*"; return 0; }
die() { echo "deadman: ERROR: $*" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}" 2>/dev/null; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"; }
is_armed() { # timer exists and has not fired yet (test mode: the armed-at marker exists)
  if [[ "$SKIP_SERVICES" == 1 ]]; then [[ -f "$STATE/armed-at" ]] && ! rolled_back_since_arm; return; fi
  [[ "$(systemctl show -p SubState --value "$UNIT.timer" 2>/dev/null)" == "waiting" ]]
}
# $STATE/armed-at is written by arm (which first deletes restored-at) and removed by a successful
# disarm. $STATE/restored-at is written by every restore before it touches a file. Both present =
# a rollback ran in this session. No timestamp comparison: a boot-time restore may run with the
# clock still wrong (before NTP sync).
rolled_back_since_arm() { [[ -f "$STATE/armed-at" && -f "$STATE/restored-at" ]]; }
restore_running() { # the timer's or the boot unit's rollback
  [[ "$SKIP_SERVICES" == 1 ]] && return 1
  local u
  for u in "$UNIT.service" "$BOOT_UNIT"; do
    [[ "$(systemctl show -p ActiveState --value "$u" 2>/dev/null)" =~ ^(activating|active|deactivating)$ ]] && return 0
  done
  return 1
}
# A previous arm whose rollback has not run yet: the server rebooted while armed, and the boot
# unit is queued or waiting for its After= units. A new arm now would snapshot the broken state.
boot_restore_pending() {
  [[ -e "$STATE/armed" ]] && return 0
  [[ "$SKIP_SERVICES" == 1 ]] && return 1
  [[ -n "$(systemctl list-jobs --no-legend "$BOOT_UNIT" 2>/dev/null)" ]]
}
# One command at a time: arm, disarm, snapshot and restore hold $STATE/lock (fd 9) until exit.
lock() { # seconds to wait
  mkdir -p "$STATE" && exec 9>"$STATE/lock" || return 1
  flock -w "$1" 9
}
report_running() {
  echo "deadman: ROLLBACK IN PROGRESS: the timer already fired. Your changes are being reverted; check 'vps-forge-deadman status' in a minute." >&2
}
report_rollback() {
  local when
  when=$(cat "$STATE/last-restore" 2>/dev/null) || when=$(date -u -d "@$(cat "$STATE/restored-at")" +%FT%TZ 2>/dev/null)
  echo "deadman: ROLLED BACK at ${when:-unknown time}: the config was restored from the snapshot taken at arm." >&2
  if [[ -s "$STATE/restore-partial" ]]; then
    echo "deadman: ROLLBACK $(cat "$STATE/restore-partial"). Fix these by hand from the snapshot." >&2
  fi
  echo "deadman: Your changes were NOT kept. Find out why the new connection failed, then arm again and redo the change." >&2
}

# The systemd-run timer is transient and lost on reboot. This persistent unit runs the same
# restore at boot while $STATE/armed exists; disarm and restore remove the marker and the unit.
install_boot_unit() { # snapshot-dir
  local dir=$1
  mkdir -p "$(dirname "$BOOT_LINK")" || return 1
  # Never order this unit Before=ssh.service: restore runs a blocking 'systemctl restart ssh'.
  cat > "$BOOT_FILE.tmp" <<UNIT_EOF || return 1
[Unit]
Description=vps-forge deadman: roll back a change that was still armed at reboot
ConditionPathExists=$STATE/armed
After=local-fs.target network.target ssh.service ssh.socket ufw.service nftables.service fail2ban.service

[Service]
Type=oneshot
TimeoutStartSec=5min
ExecStart=/bin/bash $STATE/bin/deadman.sh restore --armed $dir

[Install]
WantedBy=multi-user.target
UNIT_EOF
  chmod 644 "$BOOT_FILE.tmp" && mv -f "$BOOT_FILE.tmp" "$BOOT_FILE" || return 1
  ln -sfn "/etc/systemd/system/$BOOT_UNIT" "$BOOT_LINK" || return 1
  [[ "$SKIP_SERVICES" == 1 ]] || systemctl daemon-reload
}
# Also ends the arm: $STATE/armed-snapshot is what the timer and the boot unit check before
# they roll back, so a stale one (from an older arm) never acts on the current state.
remove_boot_unit() { rm -f "$STATE/armed" "$STATE/armed-snapshot" "$BOOT_LINK" "$BOOT_FILE" "$BOOT_FILE.tmp"; }

valid_ip() { # an IPv4 or IPv6 literal
  local ip=${1:-} o
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
    return 0
  fi
  [[ ${#ip} -le 45 && "$ip" == *:*:* && "$ip" =~ ^[0-9A-Fa-f:]+(:[0-9]{1,3}(\.[0-9]{1,3}){3})?$ ]] || return 1
  [[ ! "$ip" =~ [0-9A-Fa-f]{5} && "$ip" != *:::* && "${ip#*::}" != *::* ]]
}
client_ip() { # address of the SSH client that runs this; sudo drops SSH_CLIENT, so walk up the parents
  local v=${SSH_CLIENT:-${SSH_CONNECTION:-}} pid=$$ i
  for ((i = 0; i < 16 && ${#v} == 0; i++)); do
    pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || break
    v=$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | sed -n 's/^SSH_CLIENT=//p; s/^SSH_CONNECTION=//p' | head -n 1)
  done
  v=${v%% *}
  valid_ip "$v" && echo "$v"
}
recorded_ip() { # snapshot-dir -> the validated address saved at arm, or nothing
  local ip=""
  [[ -f "$1/unban-ip" ]] && read -r ip < "$1/unban-ip"
  valid_ip "$ip" && echo "$ip"
}
# Verification logins can trip fail2ban; a rollback that leaves the user banned doesn't help.
# Runs last in restore: a fail2ban restart re-applies bans from its database.
unban_client() { # snapshot-dir
  local ip i
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  systemctl is-active --quiet fail2ban 2>/dev/null || return 0
  ip=$(recorded_ip "$1")
  if [[ -z "$ip" ]]; then
    log "NOTE: no client IP was recorded at arm. If fail2ban banned you, run from the console: fail2ban-client unban <your-ip>"
    return 0
  fi
  for ((i = 0; i < 10; i++)); do timeout 5 fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
  if timeout 20 fail2ban-client unban "$ip" >/dev/null 2>&1; then
    log "fail2ban: unbanned $ip in all jails"
  else
    log "WARNING: 'fail2ban-client unban $ip' failed; run it from the console"
  fi
}

snapshot() { # -> prints snapshot dir
  local ts dir p u existing=() absent=() keep
  ts=$(date +%Y%m%d-%H%M%S)
  # unique even within one second: a second snapshot must never overwrite the armed one
  mkdir -p "$STATE" && dir=$(mktemp -d "$STATE/$ts-XXXX") || die "cannot create a snapshot dir in $STATE"
  for p in "${PATHS[@]}"; do
    if [[ -e "${ROOT%/}/$p" || -L "${ROOT%/}/$p" ]]; then existing+=("$p"); else absent+=("$p"); fi
  done
  ((${#existing[@]})) || die "nothing to snapshot"
  tar -C "$ROOT" -cpf "$dir/snapshot.tar" "${existing[@]}" || die "tar failed"
  printf '%s\n' "${existing[@]}" > "$dir/paths"
  printf '%s\n' "${absent[@]}" > "$dir/absent"
  if [[ "$SKIP_SERVICES" != 1 ]]; then
    for u in "${UNITS[@]}"; do echo "$u $(systemctl is-enabled "$u" 2>/dev/null | head -n 1)"; done > "$dir/units"
    # tables present now; a rollback deletes only newer ones that the rolled-back config declares
    command -v nft >/dev/null 2>&1 && { nft list tables > "$dir/nft-tables" 2>/dev/null || rm -f "$dir/nft-tables"; }
  fi
  {
    local ufw_active=0 ssh_socket=0 nft_active=0
    if [[ "$SKIP_SERVICES" != 1 ]]; then
      command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' && ufw_active=1
      systemctl is-enabled --quiet ssh.socket 2>/dev/null && ssh_socket=1
      systemctl is-active --quiet nftables 2>/dev/null && nft_active=1
    fi
    echo "ufw_active=$ufw_active"; echo "ssh_socket=$ssh_socket"; echo "nft_active=$nft_active"
    echo "created=$(date -u +%FT%TZ)"
  } > "$dir/meta"
  ln -sfn "$dir" "$STATE/latest"
  # keep the newest $KEEP snapshots, and never the armed one or the target of latest
  keep=" $(basename "$(readlink -f "$STATE/latest")") $(basename "$(cat "$STATE/armed-snapshot" 2>/dev/null)") $(basename "$(cat "$STATE/armed" 2>/dev/null)") "
  find "$STATE" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' | sort | head -n -"$KEEP" \
    | while read -r old; do [[ "$keep" == *" $old "* ]] || rm -rf "${STATE:?}/$old"; done
  echo "$dir"
}

swap_in() { # src dst bak: replace dst with src; the replaced version is moved to bak
  local src=$1 dst=$2 bak=$3 new="$2.vps-forge-new" moved=0
  rm -rf "$new"
  cp -a "$src" "$new" || { log "ERROR: copy failed for $dst"; rm -rf "$new"; return 1; }
  if [[ -e "$dst" || -L "$dst" ]]; then
    # If the current version can't be moved aside, a plain mv below would drop the snapshot
    # copy INSIDE the old directory and leave the old config in force.
    if ! { mkdir -p "$(dirname "$bak")" && rm -rf "$bak" && mv -T "$dst" "$bak"; }; then
      log "ERROR: cannot move $dst aside to $bak; $dst was NOT restored"
      rm -rf "$new"
      return 1
    fi
    moved=1
  fi
  if ! mv -T "$new" "$dst"; then
    # Put the moved-aside version back rather than leave the path missing.
    if ((moved)) && mv -T "$bak" "$dst"; then
      log "ERROR: cannot move the snapshot copy into $dst; the current version was put back, $dst was NOT restored"
    elif ((moved)); then
      log "ERROR: cannot move the snapshot copy into $dst and $dst is now MISSING: move $new (or $bak) to $dst by hand"
    else
      log "ERROR: cannot move the snapshot copy $new into $dst"
    fi
    return 1
  fi
}

# Re-apply the enable state recorded at snapshot time. Runs after the files are restored and
# systemd reloaded: a restored file can itself add or remove a mask symlink.
restore_unit_states() { # snapshot-dir
  local u was now
  [[ -f "$1/units" ]] || return 0
  while read -r u was; do
    case "$was" in enabled|disabled|masked) ;; *) continue ;; esac
    now=$(systemctl is-enabled "$u" 2>/dev/null | head -n 1)
    [[ -z "$now" || "$now" == not-found || "$now" == "$was" ]] && continue
    if [[ "$was" == masked ]]; then
      systemctl mask "$u" >/dev/null 2>&1
    else
      [[ "$now" != masked* ]] || systemctl unmask "$u" >/dev/null 2>&1
      if [[ "$was" == enabled ]]; then systemctl enable "$u" >/dev/null 2>&1; else systemctl disable "$u" >/dev/null 2>&1; fi
    fi && log "$u: $now -> $was (as at snapshot time)" || log "WARNING: could not set $u back to $was"
  done < "$1/units"
}

nft_declared_tables() { # files/dirs... -> "family name" for every table they declare
  grep -rhE '^[[:space:]]*((add|create)[[:space:]]+)?table[[:space:]]' "$@" 2>/dev/null | awk '{
    i = ($1 == "add" || $1 == "create") ? 2 : 1; f = $(i+1); n = $(i+2)
    if (f !~ /^(ip|ip6|inet|arp|bridge|netdev)$/) { n = f; f = "ip" }
    sub(/[{;].*/, "", n); if (n != "") print f, n }'
}
# Never "delete every table added since arm": ufw (iptables-nft), fail2ban and docker add theirs
# at runtime. Delete only a table that did not exist at arm AND is declared in config that this
# rollback removed or replaced (a table loaded from the rolled-back /etc/nftables.conf).
drop_new_nft_tables() { # snapshot-dir rolled-back-dir changed-paths...
  local dir=$1 rb=$2 p fam name declared files=()
  shift 2
  [[ -f "$dir/nft-tables" ]] && command -v nft >/dev/null 2>&1 || return 0
  for p in "$@"; do [[ -e "$rb/$p" ]] && files+=("$rb/$p"); done
  ((${#files[@]})) || return 0
  declared=$(nft_declared_tables "${files[@]}")
  [[ -n "$declared" ]] || return 0
  while read -r _ fam name; do
    [[ -n "$name" ]] && ! grep -qxF "table $fam $name" "$dir/nft-tables" && grep -qxF "$fam $name" <<<"$declared" || continue
    if nft delete table "$fam" "$name"; then log "nftables: deleted table $fam $name (loaded after the snapshot from the rolled-back config)"
    else log "WARNING: could not delete nftables table $fam $name"; fi
  done < <(nft list tables 2>/dev/null)
}

restore() { # snapshot-dir
  local dir=${1:-} tmp p ufw_active=0 ssh_socket=0 nft_active=0 failed=() changed=() gone
  [[ -n "$dir" && -f "$dir/snapshot.tar" ]] || die "no snapshot found (looked at ${dir:-$STATE/latest})"
  log "restoring SSH/firewall/sudo/PAM config from $dir"
  local rb
  rb="$dir/rolled-back-$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp -d) || die "mktemp failed"
  tar -C "$tmp" -xpf "$dir/snapshot.tar" || { rm -rf "$tmp"; die "cannot extract snapshot"; }
  # Record the rollback before touching any file, so disarm can never report "changes kept" after it.
  date +%s > "$STATE/restored-at"
  rm -f "$STATE/restore-partial"
  while read -r p; do
    [[ -n "$p" ]] && [[ -e "$tmp/$p" || -L "$tmp/$p" ]] || continue
    diff -rq --no-dereference "$tmp/$p" "${ROOT%/}/$p" >/dev/null 2>&1 || changed+=("$p")
    if swap_in "$tmp/$p" "${ROOT%/}/$p" "$rb/$p"; then log "restored /$p"; else failed+=("/$p"); fi
  done < "$dir/paths"
  rm -rf "$tmp"
  # the boot-time rollback must not run again (and revert later fixes) after this one
  remove_boot_unit || log "WARNING: cannot remove $STATE/armed or $BOOT_FILE; delete them by hand"
  # Paths created AFTER the snapshot (a new /etc/nftables.conf, an ssh.socket port override) are
  # moved aside too. Snapshots without an "absent" list predate it: only the two systemd dirs.
  if [[ -f "$dir/absent" ]]; then gone=$(cat "$dir/absent")
  else gone=$(printf '%s\n' etc/systemd/system/ssh.socket.d etc/systemd/system/ssh.service.d); fi
  while read -r p; do
    [[ -n "$p" ]] && ! grep -qxF "$p" "$dir/paths" && [[ -e "${ROOT%/}/$p" || -L "${ROOT%/}/$p" ]] || continue
    if mkdir -p "$(dirname "$rb/$p")" && mv -T "${ROOT%/}/$p" "$rb/$p"; then
      log "removed /$p (created after the snapshot)"
      changed+=("$p")
    else
      log "ERROR: cannot move /$p (created after the snapshot) aside"
      failed+=("/$p (not removed)")
    fi
  done <<<"$gone"
  # shellcheck disable=SC1091
  [[ -f "$dir/meta" ]] && . "$dir/meta"
  date -u +%FT%TZ > "$STATE/last-restore"
  local partial=""
  if ((${#failed[@]})); then
    partial="PARTIAL: NOT restored: ${failed[*]}"
    log "ROLLBACK $partial. Fix these by hand from $dir/snapshot.tar (provider console if SSH is down)"
    echo "$partial" > "$STATE/restore-partial"
  fi

  if [[ "$SKIP_SERVICES" == 1 ]]; then
    log "service actions skipped (test mode); fail2ban unban skipped for: $(recorded_ip "$dir" || echo none)"
    [[ -z "$partial" ]]
    return
  fi

  if command -v visudo >/dev/null 2>&1; then
    visudo -c >/dev/null 2>&1 && log "sudoers OK" || log "WARNING: visudo -c reports a problem"
  fi

  # /run/sshd is ssh.service's RuntimeDirectory: it disappears when sshd has failed or stopped,
  # and without it even a valid config fails `sshd -t`. Recreate it before validating.
  install -d -m 0755 /run/sshd 2>/dev/null
  systemctl daemon-reload
  restore_unit_states "$dir"
  # a socket started in the window would keep the port and stop ssh.service from binding it
  if grep -qE '^ssh\.socket (disabled|masked)' "$dir/units" 2>/dev/null && systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl stop ssh.socket && log "ssh.socket stopped (it was not enabled at snapshot time)"
  fi
  if sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
    if [[ "$ssh_socket" == 1 ]] || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      systemctl restart ssh.socket && log "ssh.socket restarted"
    fi
    if systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null; then
      log "ssh (re)started (existing sessions are kept)"
    else
      log "WARNING: ssh did not start; check 'journalctl -u ssh' via the provider console"
    fi
  else
    log "WARNING: sshd -t fails even on the restored config: $( (sshd -t 2>&1 || true) | head -n 1). ssh NOT restarted; use the provider console"
  fi

  drop_new_nft_tables "$dir" "$rb" "${changed[@]}"
  # nftables.service started in the window: stop it, but without its ExecStop (`nft flush ruleset`),
  # which would also wipe ufw's, fail2ban's and docker's rules. Its own tables are gone above.
  if grep -qx 'nft_active=0' "$dir/meta" 2>/dev/null && systemctl is-active --quiet nftables 2>/dev/null; then
    local dropin=/run/systemd/system/nftables.service.d/zz-vps-forge-deadman.conf
    if mkdir -p "${dropin%/*}" && printf '[Service]\nExecStop=\n' > "$dropin" && systemctl daemon-reload \
       && systemctl stop nftables; then
      log "nftables.service stopped (it was inactive at snapshot time; ruleset not flushed)"
    else
      log "WARNING: could not stop nftables.service"
    fi
    rm -f "$dropin"; systemctl daemon-reload
  fi

  local f2b_restart=0
  if [[ " ${changed[*]} " == *" etc/iptables "* ]] && systemctl is-active --quiet netfilter-persistent 2>/dev/null; then
    # iptables-restore flushes the tables it loads, Docker's chains included
    if systemctl is-active --quiet docker 2>/dev/null; then
      log "WARNING: /etc/iptables restored but NOT reloaded (Docker is running). Reload manually: netfilter-persistent reload && systemctl restart docker fail2ban"
    elif netfilter-persistent reload >/dev/null 2>&1; then
      log "netfilter-persistent reloaded with the previous /etc/iptables rules"; f2b_restart=1
    else
      log "WARNING: 'netfilter-persistent reload' failed"
    fi
  fi

  if command -v ufw >/dev/null 2>&1; then
    local now=0
    ufw status 2>/dev/null | grep -q '^Status: active' && now=1
    if [[ "$ufw_active" == 1 ]]; then
      if [[ $now == 1 ]]; then ufw reload >/dev/null && log "ufw reloaded with previous rules"
      else ufw --force enable >/dev/null && log "ufw re-enabled with previous rules"; fi
    elif [[ $now == 1 ]]; then
      ufw --force disable >/dev/null && log "ufw disabled (it was inactive before arm)"
    fi
  fi

  if [[ "$nft_active" == 1 && "$ufw_active" != 1 && -f /etc/nftables.conf ]]; then
    # Debian's nftables.conf usually starts with "flush ruleset", which would also wipe Docker's
    # and fail2ban's tables. Only reload automatically when Docker isn't running.
    if systemctl is-active --quiet docker 2>/dev/null; then
      log "WARNING: /etc/nftables.conf restored but NOT reloaded (Docker is running). Reload manually: nft -f /etc/nftables.conf && systemctl restart docker fail2ban"
    elif nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf; then
      log "nftables ruleset reloaded"; f2b_restart=1
    fi
  fi
  ((f2b_restart)) && systemctl is-active --quiet fail2ban 2>/dev/null && systemctl restart fail2ban

  unban_client "$dir"

  if [[ -n "$partial" ]]; then
    log "restore INCOMPLETE ($partial); the config that was replaced is kept in $rb"
  else
    log "restore complete; the config that was replaced is kept in $rb"
  fi
  if [[ -x /usr/local/bin/vps-notify ]]; then
    /usr/local/bin/vps-notify "Deadman fired" "SSH/firewall config on $(hostname) was rolled back to $(basename "$dir")${partial:+. $partial}" high >/dev/null 2>&1 || true
  fi
  command -v wall >/dev/null 2>&1 && echo "vps-forge deadman: config rolled back to $(basename "$dir")${partial:+. $partial}" | wall 2>/dev/null
  [[ -z "$partial" ]]
}

cmd=${1:-}; shift || true
case "$cmd" in
  arm)
    need_root
    min=5 ip=""
    while (($#)); do
      case "$1" in
        --ip) [[ $# -ge 2 ]] || die "--ip needs an address"; ip=$2; shift 2 ;;
        --ip=*) ip=${1#--ip=}; shift ;;
        *) min=$1; shift ;;
      esac
    done
    if [[ -n "$ip" ]]; then valid_ip "$ip" || die "--ip: not an IP address: $ip"
    else ip=$(client_ip) || ip=""; fi
    [[ "$min" =~ ^[0-9]+$ ]] && (( min >= 1 && min <= 120 )) || die "MINUTES must be 1..120"
    [[ "$SKIP_SERVICES" == 1 || -d /run/systemd/system ]] || die "systemd is not running; cannot schedule a rollback"
    lock 10 || die "another vps-forge-deadman command is running; try again"
    if is_armed; then
      die "already armed. Disarm first (re-arming would snapshot a possibly broken state)"
    fi
    if restore_running; then
      die "a rollback is running right now; wait for it to finish ('vps-forge-deadman status')"
    fi
    if boot_restore_pending; then
      die "the previous arm's rollback has not run yet (the server rebooted while armed; $BOOT_UNIT rolls back to $(basename "$(cat "$STATE/armed" 2>/dev/null)")). Wait for it ('vps-forge-deadman status'), or keep the current config with 'vps-forge-deadman disarm'"
    fi
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    [[ -n "$self" && -f "$self" ]] || die "run from an installed file (install -m 755 deadman.sh /usr/local/sbin/vps-forge-deadman), not via a pipe"
    if [[ -f /var/run/reboot-required ]]; then
      log "NOTE: a reboot is pending. Don't reboot while armed: the change would be rolled back at boot"
    fi
    dir=$(snapshot) || exit 1
    if [[ -n "$ip" ]]; then
      echo "$ip" > "$dir/unban-ip" || die "cannot write $dir/unban-ip"
      ip_note="fail2ban unban on rollback: $ip"
    else
      ip_note="no client IP found, pass --ip ADDR to unban it on rollback"
    fi
    install -d -m 700 "$STATE/bin" && install -m 700 "$self" "$STATE/bin/deadman.sh" \
      || die "cannot install $STATE/bin/deadman.sh"
    # a new arm starts a new session: an older rollback no longer counts
    rm -f "$STATE/restored-at" "$STATE/restore-partial" && date +%s > "$STATE/armed-at" || die "cannot write $STATE/armed-at"
    if install_boot_unit "$dir" && echo "$dir" > "$STATE/armed"; then
      boot_note="a reboot while armed also rolls back"
    else
      remove_boot_unit
      log "WARNING: could not install $BOOT_UNIT; a reboot while armed would skip the rollback"
      boot_note="NO rollback after a reboot"
    fi
    # the arm's identity: the timer and the boot unit roll back only while it names their snapshot
    echo "$dir" > "$STATE/armed-snapshot" || { rm -f "$STATE/armed-at"; remove_boot_unit; die "cannot write $STATE/armed-snapshot"; }
    if [[ "$SKIP_SERVICES" == 1 ]]; then
      log "ARMED (test mode: no timer scheduled, snapshot $(basename "$dir"); $boot_note; $ip_note)"
      exit 0
    fi
    systemctl stop "$UNIT.timer" 2>/dev/null; systemctl reset-failed "$UNIT.service" "$UNIT.timer" 2>/dev/null
    systemd-run --quiet --collect --unit="$UNIT" --description="vps-forge deadman rollback" \
      --on-active="${min}m" --timer-property=AccuracySec=1s \
      /bin/bash "$STATE/bin/deadman.sh" restore --armed "$dir" || { rm -f "$STATE/armed-at"; remove_boot_unit; die "systemd-run failed"; }
    at=$(date -d "+${min} min" +%H:%M:%S 2>/dev/null || echo "in ${min} min")
    log "ARMED: rollback at $at unless you run 'vps-forge-deadman disarm' (snapshot $(basename "$dir"); $boot_note; $ip_note)"
    ;;
  extend)
    need_root
    min=${1:-}
    [[ "$min" =~ ^[0-9]+$ ]] && (( min >= 1 && min <= 120 )) || die "usage: extend MINUTES (1..120)"
    lock 10 || die "another vps-forge-deadman command is running; NOT extended. Try again"
    if rolled_back_since_arm; then report_rollback; exit 3; fi
    if restore_running; then report_running; exit 3; fi
    is_armed || die "not armed: nothing to extend"
    dir=$(cat "$STATE/armed-snapshot" 2>/dev/null)
    [[ -n "$dir" && -d "$dir" ]] || die "no armed snapshot recorded; NOT extended"
    if [[ "$SKIP_SERVICES" == 1 ]]; then
      log "EXTENDED (test mode: no timer scheduled, snapshot $(basename "$dir"))"
      exit 0
    fi
    systemctl stop "$UNIT.timer" || die "could not stop $UNIT.timer; the old rollback time still holds"
    # the timer may have fired between the checks above and the stop
    if rolled_back_since_arm; then report_rollback; exit 3; fi
    if restore_running; then report_running; exit 3; fi
    systemctl reset-failed "$UNIT.service" "$UNIT.timer" 2>/dev/null
    if ! systemd-run --quiet --collect --unit="$UNIT" --description="vps-forge deadman rollback"         --on-active="${min}m" --timer-property=AccuracySec=1s         /bin/bash "$STATE/bin/deadman.sh" restore --armed "$dir"; then
      # no timer now means no rollback: an unverified change must not outlive the arm
      log "systemd-run failed while extending: rolling back now"
      restore "$dir"; exit 1
    fi
    at=$(date -d "+${min} min" +%H:%M:%S 2>/dev/null || echo "in ${min} min")
    log "EXTENDED: rollback at $at unless you run 'vps-forge-deadman disarm' (snapshot $(basename "$dir"))"
    ;;
  disarm)
    need_root
    # a long rollback holds the lock: report it (exit 3) rather than "try again"
    if restore_running; then report_running; exit 3; fi
    lock 30 || die "another vps-forge-deadman command is running; NOT disarmed. Try again"
    # Never stop a running restore: a half-swapped /etc/ssh is worse than either state.
    if rolled_back_since_arm; then report_rollback; exit 3; fi
    if restore_running; then report_running; exit 3; fi
    if is_armed; then
      if [[ "$SKIP_SERVICES" != 1 ]]; then
        systemctl stop "$UNIT.timer" || die "could not stop $UNIT.timer; the rollback may still fire"
      fi
      # the timer may have elapsed between the checks above and the stop
      if rolled_back_since_arm; then report_rollback; exit 3; fi
      if restore_running; then report_running; exit 3; fi
      remove_boot_unit || die "cannot remove $STATE/armed or $BOOT_FILE: the next reboot would roll back. Delete them by hand"
      rm -f "$STATE/armed-at" || die "cannot remove $STATE/armed-at"
      log "disarmed: changes kept"
    elif [[ -f "$STATE/armed-at" ]]; then
      remove_boot_unit || die "cannot remove $STATE/armed or $BOOT_FILE: the next reboot would roll back. Delete them by hand"
      rm -f "$STATE/armed-at"
      log "WARNING: no rollback timer was waiting, but no rollback was recorded either; changes kept"
    else
      log "not armed"
    fi
    ;;
  status)
    if is_armed; then
      echo "ARMED"; systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null | sed -n '1,2p'
    else
      echo "not armed"
    fi
    [[ -f "$STATE/armed" ]] && echo "reboot protection: on ($BOOT_UNIT rolls back to $(basename "$(cat "$STATE/armed")") at boot)"
    if rolled_back_since_arm; then
      echo "ROLLED BACK since the last arm (at $(cat "$STATE/last-restore" 2>/dev/null || echo '?')): changes were NOT kept"
    elif [[ -f "$STATE/last-restore" ]]; then
      echo "last rollback: $(cat "$STATE/last-restore")"
    fi
    [[ -s "$STATE/restore-partial" ]] && echo "that rollback was $(cat "$STATE/restore-partial")"
    echo "snapshots:"; find "$STATE" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '  %f\n' 2>/dev/null | sort
    ;;
  restore)
    need_root
    if [[ "${1:-}" == --armed ]]; then
      # internal: the timer and the boot unit. Never wait forever: a skipped rollback is a lockout.
      lock 300 || log "WARNING: $STATE/lock still held after 5 minutes; rolling back anyway"
      if [[ -z "${2:-}" || "$(cat "$STATE/armed-snapshot" 2>/dev/null)" != "$2" ]]; then
        log "not rolling back to $(basename "${2:-?}"): it is not the armed snapshot any more (disarmed, already rolled back, or armed again)"
        exit 0
      fi
      restore "$2"; exit
    fi
    restore_running && die "a rollback is running right now; wait for it to finish ('vps-forge-deadman status')"
    lock 60 || die "another vps-forge-deadman command is running; try again"
    dir=${1:-}
    [[ -n "$dir" ]] || dir=$(cat "$STATE/armed-snapshot" 2>/dev/null)
    [[ -n "$dir" ]] || dir=$(readlink -f "$STATE/latest" 2>/dev/null)
    is_armed && [[ "$SKIP_SERVICES" != 1 ]] && systemctl stop "$UNIT.timer"
    restore "$dir"
    ;;
  snapshot)
    need_root
    lock 30 || die "another vps-forge-deadman command is running; try again"
    dir=$(snapshot) || exit 1
    log "snapshot saved: $dir"
    ;;
  client-ip)
    client_ip || die "no SSH client found for this session (run it inside an SSH session; sudo is fine)"
    ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
