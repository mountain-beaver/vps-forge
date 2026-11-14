#!/usr/bin/env bash
# vps-forge alerts installer: phone alerts for a Debian/Ubuntu server.
#
# Usage (as root):  install-alerts.sh [--ssh-login] [--health] [--all] [--test] [--uninstall]
#   remote:         ssh host 'sudo bash -s -- --all --test' < install-alerts.sh
#
# Always installs /usr/local/bin/vps-notify (ntfy / Telegram / webhook sender).
#   --ssh-login  alert on SSH logins: a new user@address loudly, known ones quietly and at most
#                hourly (pam_exec, optional + non-blocking)
#   --health     timer every 5 min: failed units, disk, inodes, reboot, OOM kills, overdue backup, heartbeat
#   --all        both of the above
#   --test       send a test message after installing
#   --uninstall  remove everything except /etc/vps-forge/notify.env
#
# Channels and thresholds live in /etc/vps-forge/notify.env (mode 600). If it doesn't exist,
# a commented template is created and nothing is sent until it is filled in.
# Idempotent: safe to re-run. Part of vps-forge (MIT).

set -euo pipefail
umask 022

SSH_LOGIN=0; HEALTH=0; TEST=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --ssh-login) SSH_LOGIN=1 ;;
    --health) HEALTH=1 ;;
    --all) SSH_LOGIN=1; HEALTH=1 ;;
    --test) TEST=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,19p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || echo "see header of install-alerts.sh"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

CONF_DIR=/etc/vps-forge
CONF=$CONF_DIR/notify.env
PAM_LINE='session optional pam_exec.so quiet /usr/local/sbin/vps-forge-ssh-login'

say() { echo "install-alerts: $*"; }

if (( UNINSTALL )); then
  systemctl disable --now vps-forge-health.timer 2>/dev/null || true
  rm -f /etc/systemd/system/vps-forge-health.{service,timer}
  systemctl daemon-reload 2>/dev/null || true
  if [[ -f /etc/pam.d/sshd ]] && grep -qF "$PAM_LINE" /etc/pam.d/sshd; then
    tmp=$(mktemp); grep -vF "$PAM_LINE" /etc/pam.d/sshd > "$tmp"; cat "$tmp" > /etc/pam.d/sshd; rm -f "$tmp"
  fi
  rm -f /usr/local/bin/vps-notify /usr/local/sbin/vps-forge-health /usr/local/sbin/vps-forge-ssh-login
  rm -rf /var/lib/vps-forge/alerts
  say "uninstalled (kept $CONF)"
  exit 0
fi

command -v curl >/dev/null || { say "installing curl"; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null; }

# ------------------------------------------------------------ notify.env ---
install -d -m 700 "$CONF_DIR"
if [[ ! -f "$CONF" ]]; then
  # Create it 600 first: the umask is 022, and a world-readable file must never hold tokens.
  install -m 600 /dev/null "$CONF"
  cat > "$CONF" <<'EOF'
# /etc/vps-forge/notify.env (mode 600): read by vps-notify and vps-forge-health.
# Shell syntax: keep values in single quotes. Leave a channel empty to disable it.

# ntfy (https://ntfy.sh or self-hosted). Public topics are readable by anyone who
# knows the name: use a long random topic (openssl rand -hex 16) or an access token.
NTFY_URL=''
NTFY_TOKEN=''

# Telegram: create a bot with @BotFather; chat id from https://api.telegram.org/bot<token>/getUpdates
TELEGRAM_BOT_TOKEN=''
TELEGRAM_CHAT_ID=''

# Generic webhook. WEBHOOK_FORMAT: slack | discord | json
WEBHOOK_URL=''
WEBHOOK_FORMAT='json'

# healthchecks.io (or self-hosted) check pinged every 5 minutes by the health timer
HC_HEARTBEAT_URL=''

# Thresholds
DISK_WARN_PCT=85
INODE_WARN_PCT=90
REALERT_HOURS=6
# Alert when the last successful vps-forge restic backup is older than this
BACKUP_MAX_AGE_HOURS=36

# Space-separated IPs that do not trigger SSH login alerts
SSH_ALERT_IGNORE_IPS=''
# A user@address seen within this many days is known: its logins come at low priority
# (no sound) and at most once an hour. The first login from a new one is high priority.
SSH_ALERT_KNOWN_DAYS=30
EOF
  say "created $CONF template: fill in at least one channel"
fi
chmod 600 "$CONF"; chown root:root "$CONF"

# ------------------------------------------------------------ vps-notify ---
cat > /usr/local/bin/vps-notify <<'EOF'
#!/usr/bin/env bash
# vps-notify TITLE [MESSAGE] [low|default|high]: send to every channel in /etc/vps-forge/notify.env.
# Secrets are passed to curl via a config on stdin, never on the command line (visible in ps).
# Exit: 0 sent to at least one channel, 1 all channels failed, 2 no channel configured.
set -u
CONF=${VPS_NOTIFY_CONF:-/etc/vps-forge/notify.env}
if [[ -r "$CONF" ]]; then
  # shellcheck disable=SC1090
  . "$CONF"
elif [[ -e "$CONF" ]]; then
  echo "vps-notify: cannot read $CONF (run as root)" >&2; exit 2
fi
title=${1:?usage: vps-notify TITLE [MESSAGE] [low|default|high]}
msg=${2:-$1}
prio=${3:-default}
host=$(hostname -s 2>/dev/null || hostname)

cfg() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}; printf '"%s"' "$s"; }
json() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}; printf '"%s"' "$s"; }
urlenc() {
  local LC_ALL=C s=$1 out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v c '%%%02X' "'$c"; out+="$c" ;; esac
  done
  printf '%s' "$out"
}
send() { curl -fsS --max-time 10 --retry 2 --retry-delay 2 -K - >/dev/null 2>&1; }

case "$prio" in high) icon="🔴"; np=high ;; low) icon="⚪"; np=low ;; *) icon="🟡"; np=default ;; esac
tried=0; sent=0

if [[ -n "${NTFY_URL:-}" ]]; then
  tried=$((tried+1))
  sep='?'; [[ "$NTFY_URL" == *\?* ]] && sep='&'
  {
    echo "url = $(cfg "${NTFY_URL}${sep}title=$(urlenc "[$host] $title")&priority=$np")"
    [[ -n "${NTFY_TOKEN:-}" ]] && echo "header = $(cfg "Authorization: Bearer $NTFY_TOKEN")"
    echo "data-binary = $(cfg "$msg")"
  } | send && sent=$((sent+1))
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  tried=$((tried+1))
  {
    echo "url = $(cfg "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")"
    echo "data-urlencode = $(cfg "chat_id=$TELEGRAM_CHAT_ID")"
    echo "data-urlencode = $(cfg "text=$icon [$host] $title"$'\n'"$msg")"
    echo "data-urlencode = \"disable_web_page_preview=true\""
  } | send && sent=$((sent+1))
fi

if [[ -n "${WEBHOOK_URL:-}" ]]; then
  tried=$((tried+1))
  text="$icon [$host] $title"$'\n'"$msg"
  case "${WEBHOOK_FORMAT:-json}" in
    slack) body="{\"text\":$(json "$text")}" ;;
    discord) body="{\"content\":$(json "$text")}" ;;
    *) body="{\"host\":$(json "$host"),\"title\":$(json "$title"),\"message\":$(json "$msg"),\"priority\":$(json "$prio")}" ;;
  esac
  {
    echo "url = $(cfg "$WEBHOOK_URL")"
    echo 'header = "Content-Type: application/json"'
    echo "data-binary = $(cfg "$body")"
  } | send && sent=$((sent+1))
fi

if (( tried == 0 )); then echo "vps-notify: no channel configured in $CONF" >&2; exit 2; fi
if (( sent == 0 )); then echo "vps-notify: all $tried channel(s) failed" >&2; exit 1; fi
exit 0
EOF
chmod 755 /usr/local/bin/vps-notify
say "installed /usr/local/bin/vps-notify"

# ------------------------------------------------------------- ssh login ---
if (( SSH_LOGIN )); then
  cat > /usr/local/sbin/vps-forge-ssh-login <<'EOF'
#!/bin/sh
# Called by pam_exec on SSH session open. Must never block or fail a login.
# pam_exec inherits the PAM environment: scrub it so a user cannot point root's
# notifier at their own config, and use a fixed PATH for the helpers below.
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset VPS_NOTIFY_CONF
CONF=/etc/vps-forge/notify.env
IGN=""
[ -r "$CONF" ] && IGN=$(sed -n "s/^SSH_ALERT_IGNORE_IPS=//p" "$CONF" | tr -d "\"'")
for ip in $IGN; do [ "$ip" = "${PAM_RHOST:-}" ] && exit 0; done
DAYS=""
[ -r "$CONF" ] && DAYS=$(sed -n "s/^SSH_ALERT_KNOWN_DAYS=//p" "$CONF" | tr -cd '0-9')
when=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Everything below runs in the background, so a slow disk or network never delays the login.
(
  u=${PAM_USER:-?}; h=${PAM_RHOST:-unknown}
  prio=high; note="new address"
  d=/var/lib/vps-forge/alerts/ssh-seen
  k=$(printf '%s@%s' "$u" "$h" | tr -c 'A-Za-z0-9@._:-' '_' | cut -c1-200)
  # SSH_ALERT_KNOWN_DAYS=0: every login is new
  if [ "${DAYS:-30}" -gt 0 ] && mkdir -p "$d" 2>/dev/null; then
    if [ -n "$(find "$d/$k.seen" -mtime -"${DAYS:-30}" 2>/dev/null)" ]; then
      prio=low; note="known address"
      # a known address that already alerted within the hour: count it, don't send again
      [ -n "$(find "$d/$k.sent" -mmin -60 2>/dev/null)" ] && { touch "$d/$k.seen"; exit 0; }
    fi
    touch "$d/$k.seen" "$d/$k.sent" 2>/dev/null
  fi
  env -i PATH="$PATH" HOME=/root /usr/local/bin/vps-notify "SSH login: $u" "$u logged in from $h at $when (${PAM_SERVICE:-sshd}, $note)" "$prio"
) </dev/null >/dev/null 2>&1 &
exit 0
EOF
  chmod 755 /usr/local/sbin/vps-forge-ssh-login
  if [[ -f /etc/pam.d/sshd ]]; then
    if ! grep -qF "$PAM_LINE" /etc/pam.d/sshd; then
      cp -a /etc/pam.d/sshd "/etc/pam.d/.sshd.vps-forge-backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      printf '\n# vps-forge: SSH login alert (optional: never blocks a login)\n%s\n' "$PAM_LINE" >> /etc/pam.d/sshd
    fi
    say "SSH login alerts enabled (pam_exec in /etc/pam.d/sshd)"
  else
    say "WARNING: /etc/pam.d/sshd not found; SSH login alert not wired"
  fi
fi

# ---------------------------------------------------------------- health ---
if (( HEALTH )); then
  cat > /usr/local/sbin/vps-forge-health <<'EOF'
#!/usr/bin/env bash
# vps-forge health check: run by vps-forge-health.timer every 5 minutes.
# Alerts once per problem, re-alerts every REALERT_HOURS, and says when a problem is resolved.
# Failed units and an overdue backup alert again promptly after a fix (15 min anti-flap) instead of
# waiting out REALERT_HOURS; disk and inodes keep the full cooldown.
set -u
export LC_ALL=C
CONF=/etc/vps-forge/notify.env
# shellcheck disable=SC1090
[[ -r "$CONF" ]] && . "$CONF"
DISK_WARN_PCT=${DISK_WARN_PCT:-85}
INODE_WARN_PCT=${INODE_WARN_PCT:-90}
REALERT_HOURS=${REALERT_HOURS:-6}
BACKUP_MAX_AGE_HOURS=${BACKUP_MAX_AGE_HOURS:-36}
# '85%' or '6h' is a syntax error inside (( )), and the check would then never
# fire: replace a bad value with the default and leave a note in the journal.
num() { # name default
  local v=${!1}
  if [[ "$v" =~ ^[0-9]+$ ]]; then return 0; fi
  echo "vps-forge-health: invalid $1='$v', using $2" >&2
  printf -v "$1" '%s' "$2"
}
num DISK_WARN_PCT 85
num INODE_WARN_PCT 90
num REALERT_HOURS 6
num BACKUP_MAX_AGE_HOURS 36
STATE=/var/lib/vps-forge/alerts
mkdir -p "$STATE" "$STATE/.sent"; chmod 700 "$STATE" "$STATE/.sent"
now=$(date +%s)
declare -A current=() seen=()

problem() { # key title message [realert_hours] [state]
  local key=$1 title=$2 msg=$3 every=${4:-$REALERT_HOURS} state=${5:-} f sum sent last=0 oldlast="" oldsum="" changed=0
  current[$key]=1
  f="$STATE/$key"
  sent="$STATE/.sent/$key"
  # Dedup on a stable state, not on the message: "86% full" after "85% full" is the same
  # problem and waits for REALERT_HOURS; another failed unit is a new state and alerts now.
  [[ -n "$state" ]] || state=$(printf '%s' "$msg" | sed -E 's/[0-9]+%/N%/g')
  sum="s1:$(printf '%s\n%s' "$key" "$state" | md5sum | cut -c1-12)"
  # Last alert time lives apart from the active state, so the resolved loop
  # cannot erase it and a flapping unit cannot bypass the cooldown.
  if [[ -f "$sent" ]]; then read -r last < "$sent" || true; fi
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [[ -f "$f" ]]; then
    read -r oldlast oldsum < "$f" || true
    # Upgrade from the old format, where the active file held "time hash".
    if (( last == 0 )) && [[ -n "$oldsum" && "$oldlast" =~ ^[0-9]+$ ]]; then last=$oldlast; fi
    # Only a known earlier state counts as a change. A missing file means the problem had
    # resolved; older hash formats are not comparable. Both fall back to the cooldown.
    [[ "$oldlast" == s1:* && "$oldlast" != "$sum" ]] && changed=1
  fi
  if (( changed || now - last >= every * 3600 )); then
    if /usr/local/bin/vps-notify "$title" "$msg" high; then
      echo "$sum" > "$f"
      echo "$now" > "$sent"
    fi
  fi
}

# Failed units. If systemctl itself fails, keep existing state: an empty result
# would otherwise look like "no failed units" and send a false resolved.
units_ok=0
if units=$(systemctl --failed --no-legend --plain 2>/dev/null); then
  units_ok=1
  failed=$(printf '%s\n' "$units" | awk '{print $1}' | paste -sd' ' -)
  [[ -n "$failed" ]] && problem failed-units "Failed services" "Failed units: $failed. Check: systemctl status <unit>; journalctl -u <unit> -n 50"
fi

# Disk and inodes. Record every filesystem df actually reported: df can omit a
# row with exit 0 (ENOENT/EACCES), and absence alone must not resolve an alert.
# A hung network mount would block df forever; timeout 20 leaves its rows out (never "resolved").
while read -r pct mnt; do
  p=${pct%\%}; [[ "$p" =~ ^[0-9]+$ ]] || continue
  key="disk$(tr '/' '_' <<<"$mnt")"
  seen[$key]=1
  (( p >= DISK_WARN_PCT )) && problem "$key" "Disk ${p}% full" "$mnt is ${p}% full (threshold ${DISK_WARN_PCT}%). Find big dirs: ncdu -x $mnt"
done < <(timeout 20 df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1{print $5, $6}')
while read -r pct mnt; do
  p=${pct%\%}; [[ "$p" =~ ^[0-9]+$ ]] || continue
  key="inode$(tr '/' '_' <<<"$mnt")"
  seen[$key]=1
  (( p >= INODE_WARN_PCT )) && problem "$key" "Inodes ${p}% used" "$mnt inode usage ${p}% (threshold ${INODE_WARN_PCT}%)"
done < <(timeout 20 df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR>1{print $5, $6}')

# reboot required (once a day)
if [[ -f /var/run/reboot-required ]]; then
  pk=$(head -c 200 /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')
  problem reboot-required "Reboot required" "Updates need a reboot${pk:+ ($pk)}. Plan a reboot." 24 reboot-required
fi

# Kernel OOM kills. An event, not a condition: every kill line is announced once. The 6 minute
# window overlaps the 5 minute timer, so lines already announced are remembered (by hash) until
# they leave the window. A journal that cannot be read changes nothing.
if oom=$(journalctl -k --since=-6min --no-pager -q 2>/dev/null); then
  oom=$(printf '%s\n' "$oom" | grep -i 'killed process' || true)
  oomseen="$STATE/.oom-seen"; hashes=""; fresh=""
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    h=$(printf '%s' "$l" | md5sum | cut -c1-12)
    hashes+="$h"$'\n'
    grep -qxF "$h" "$oomseen" 2>/dev/null || fresh+="$l"$'\n'
  done <<<"$oom"
  if [[ -z "$fresh" ]]; then
    printf '%s' "$hashes" > "$oomseen"
  elif /usr/local/bin/vps-notify "Out of memory: process killed" "$(printf '%s' "$fresh" | head -n 3 | cut -c1-240). Check: journalctl -k | grep -i 'killed process'; free -h" high; then
    printf '%s' "$hashes" > "$oomseen"
  fi
fi

# Overdue backup, when the vps-forge restic backup is set up. vps-forge-backup.sh writes the
# stamp after every fully successful run and last-partial after a run that saved a snapshot but
# could not read some files (restic exit 3; the backup script already sent a warning). A partial
# snapshot still counts as a recent backup here: repeating the overdue alert on top of the daily
# warning would only be noise. Failed runs already show up as failed units. Without a stamp
# (backup script older than this check, or never succeeded) fall back to the last successful
# run systemd remembers, then to the age of /etc/restic/env (grace for new setups).
if [[ -f /etc/restic/env && -e /etc/systemd/system/vps-forge-backup.timer ]]; then
  ok_at=0 ref=0 st="" ts="" part_at=0 stamp_ok=0 label="successful backup"
  if [[ -f /var/lib/vps-forge/backup/last-success ]]; then
    read -r ok_at < /var/lib/vps-forge/backup/last-success || true
    [[ "$ok_at" =~ ^[0-9]+$ ]] || ok_at=0
    stamp_ok=$ok_at
  fi
  if [[ -f /var/lib/vps-forge/backup/last-partial ]]; then
    read -r part_at < /var/lib/vps-forge/backup/last-partial || true
    [[ "$part_at" =~ ^[0-9]+$ ]] || part_at=0
  fi
  # key=value: systemctl prints properties in its own order, not in the -p order. The timestamp is
  # human-readable ("Thu 2026-10-22 03:00:05 UTC"; --timestamp=unix needs systemd 251, Ubuntu 22.04
  # has 249): TZ=UTC pins the zone name, and date -d turns it into seconds.
  while IFS='=' read -r k v; do
    case "$k" in ExecMainStatus) st=$v ;; ExecMainExitTimestamp) ts=$v ;; esac
  done < <(TZ=UTC systemctl show -p ExecMainStatus -p ExecMainExitTimestamp vps-forge-backup.service 2>/dev/null)
  # An empty value (the unit never ran) or "n/a" must stay empty: GNU date -d "" means today 00:00.
  if [[ "$ts" == @* ]]; then ts=${ts#@}
  elif [[ -n "$ts" && "$ts" != n/a ]]; then ts=$(date -d "$ts" +%s 2>/dev/null) || ts=""
  else ts=""; fi
  if [[ "$st" == 0 && "$ts" =~ ^[0-9]+$ ]] && (( ts > ok_at )); then ok_at=$ts; fi
  # The partial stamp is removed by the next full success, so while it is at least as new as the
  # last-success stamp the latest run was partial (its systemd exit time is a moment later).
  if (( part_at > 0 && part_at >= stamp_ok )); then
    (( part_at > ok_at )) && ok_at=$part_at
    label="backup (partial: some files were unreadable)"
  fi
  if (( ok_at > 0 )); then
    ref=$ok_at
    what="Last $label: $(date -u -d "@$ok_at" '+%F %H:%M UTC')"
  else
    ref=$(stat -c %Y /etc/restic/env 2>/dev/null) || ref=$now
    what="No successful backup recorded (restic configured $(date -u -d "@$ref" '+%F %H:%M UTC'))"
  fi
  if (( now - ref >= BACKUP_MAX_AGE_HOURS * 3600 )); then
    problem backup-stale "Backup overdue" "$what, $(( (now - ref) / 3600 ))h ago (limit ${BACKUP_MAX_AGE_HOURS}h). Check: systemctl list-timers vps-forge-backup.timer; journalctl -u vps-forge-backup -n 50" "" backup-stale
  fi
fi

# Resolved problems. Only announce a fix when the corresponding check actually
# ran and saw this key healthy; a failed or incomplete check proves nothing.
for f in "$STATE"/*; do
  [[ -f "$f" ]] || continue
  key=$(basename "$f")
  [[ -n "${current[$key]:-}" ]] && continue
  case "$key" in
    failed-units) (( units_ok )) || continue ;;
    disk*|inode*) [[ -n "${seen[$key]:-}" ]] || continue ;;
  esac
  # Keep the state if the message could not be sent: the next run announces it again.
  /usr/local/bin/vps-notify "Resolved: $key" "No longer a problem on $(hostname): $key" low || continue
  case "$key" in
    failed-units|backup-stale)
      # A new failure after a fix is news, not a repeat: end the cooldown, but only 15 minutes
      # after this fix so that a flapping unit cannot alert on every run.
      (( REALERT_HOURS * 3600 > 900 )) && echo $(( now - REALERT_HOURS * 3600 + 900 )) > "$STATE/.sent/$key" ;;
  esac
  rm -f "$f"
done

# heartbeat
if [[ -n "${HC_HEARTBEAT_URL:-}" ]]; then
  printf 'url = "%s"\n' "$HC_HEARTBEAT_URL" | curl -fsS --max-time 10 --retry 3 -K - >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 755 /usr/local/sbin/vps-forge-health

  cat > /etc/systemd/system/vps-forge-health.service <<'EOF'
[Unit]
Description=vps-forge health check (alerts)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-forge-health
Nice=10
# A hung command must not leave the oneshot "activating" forever: the timer never restarts an active unit.
TimeoutStartSec=2min
EOF
  cat > /etc/systemd/system/vps-forge-health.timer <<'EOF'
[Unit]
Description=Run vps-forge health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --now vps-forge-health.timer >/dev/null 2>&1
    say "health timer enabled (vps-forge-health.timer, every 5 min)"
  else
    say "WARNING: systemd not running; health timer installed but not started"
  fi
fi

if (( TEST )); then
  if /usr/local/bin/vps-notify "Test alert" "vps-forge alerts on $(hostname) work. If you see this, you're set." high; then
    say "test message sent: ask the user to confirm they received it"
  else
    rc=$?
    say "test message NOT sent (exit $rc): fill in $CONF"
    exit "$rc"
  fi
fi
