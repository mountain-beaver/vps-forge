#!/usr/bin/env bash
# vps-forge external check: what does the internet see? Run this on YOUR machine, not on the server.
#
# Usage: external-check.sh HOST [--port 22] [--user ADMIN] [--identity ~/.ssh/id_ed25519]
#                               [--domain example.com] [--root-test] [--ssh-audit]
#                               [--no-scan] [--no-login-tests]
#
#  - open TCP ports (nmap if installed, otherwise nc on common ports). An IPv6 literal is scanned
#    with -6; a name that has AAAA records gets a second, separately reported IPv6 pass
#  - --identity: key for the admin login. Without it ssh uses its normal keys and the agent
#  - SSH: auth methods offered (must be publickey only), admin login works
#  - --root-test: confirm root login is refused     --ssh-audit: algorithm audit (pipx install ssh-audit)
#  - with --domain: HTTP→HTTPS redirect, security headers, certificate expiry, legacy TLS
#
# fail2ban WARNING: every auth probe counts as failed logins. The unknown-user, --user and
# --root-test probes each add 1-2, and --ssh-audit opens
# many connections (its rate test is skipped when supported). Your IP should be in ignoreip in
# /etc/fail2ban/jail.d/vps-forge.local (then: sudo systemctl reload fail2ban).
# If you get banned anyway, run this from the console or another IP:
#   sudo fail2ban-client set sshd unbanip <your-ip>   (also: set recidive unbanip <your-ip>)
# Works with macOS bash 3.2 and Linux. Exit 1 if any FAIL. Part of vps-forge (MIT).

set -u

HOST=""; PORT=22; USER_NAME=""; IDENTITY=""; DOMAIN=""; SCAN=1; LOGIN=1; ROOTTEST=0; SSHAUDIT=0
need_val() { [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --port) need_val "$@"; PORT=$2; shift 2 ;;
    --user) need_val "$@"; USER_NAME=$2; shift 2 ;;
    --identity) need_val "$@"; IDENTITY=$2; shift 2 ;;
    --domain) need_val "$@"; DOMAIN=$2; shift 2 ;;
    --no-scan) SCAN=0; shift ;;
    --no-login-tests) LOGIN=0; shift ;;
    --root-test) ROOTTEST=1; shift ;;
    --ssh-audit) SSHAUDIT=1; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) HOST=$1; shift ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) echo "invalid --port: $PORT (1-65535)" >&2; exit 2 ;; esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then echo "invalid --port: $PORT (1-65535)" >&2; exit 2; fi
[ -n "$HOST" ] || { echo "usage: $0 HOST [options]  (--help)" >&2; exit 2; }
HOST=${HOST#\[}; HOST=${HOST%\]}   # [2001:db8::1] -> 2001:db8::1
V6LIT=0; case "$HOST" in *:*) V6LIT=1 ;; esac

if [ -t 1 ]; then G=$(printf '\033[32m'); Y=$(printf '\033[33m'); RD=$(printf '\033[31;1m'); C=$(printf '\033[36m'); B=$(printf '\033[1m'); N=$(printf '\033[0m')
else G=""; Y=""; RD=""; C=""; B=""; N=""; fi
FAILS=0; WARNS=0
pass() { printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  %sFAIL%s  %s\n' "$RD" "$N" "$*"; FAILS=$((FAILS+1)); }
info() { printf '  %sINFO%s  %s\n' "$C" "$N" "$*"; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
have() { command -v "$1" >/dev/null 2>&1; }
# Host part of a URL: drop scheme, query/fragment, path and userinfo before the port.
url_host() {
  local h=${1#*://}
  h=${h%%[?#]*}; h=${h%%/*}; h=${h##*@}
  case "$h" in
    \[*\]*) h=${h#\[}; h=${h%%\]*} ;;
    *) h=${h%%:*} ;;
  esac
  printf '%s' "${h%.}" | tr 'A-Z' 'a-z'
}

printf '%svps-forge external check%s → %s (ssh port %s)\n' "$B" "$N" "$HOST" "$PORT"

# ------------------------------------------------------------ admin login ---
# The legitimate login runs first. The port scan and the failing probes below open many
# connections and collect auth failures; ufw's limit rule (6 new connections in 30 s) or
# OpenSSH PerSourcePenalties could then make a working admin login look broken.
SSH_OPTS="-o ControlPath=none -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# An array, so a key path with spaces stays one argument. Without --identity add nothing: forcing
# IdentitiesOnly with a guessed default key hides the agent's keys and fakes a login failure.
# Expanded as ${ID_OPTS[@]+"${ID_OPTS[@]}"}: an empty array is an error under set -u in bash 3.2.
ID_OPTS=()
if [ -n "$IDENTITY" ]; then ID_OPTS=(-o IdentitiesOnly=yes -i "$IDENTITY"); fi
if [ "$LOGIN" = 1 ] && ! have ssh; then
  warn "ssh not found; login probes skipped (install an OpenSSH client)"
fi
if [ "$LOGIN" = 0 ] && [ "$ROOTTEST" = 1 ]; then
  warn "--root-test ignored with --no-login-tests (it is a login probe)"
fi
if have ssh && [ "$LOGIN" = 1 ] && [ -n "$USER_NAME" ]; then
  head_ "SSH ADMIN LOGIN"
  # shellcheck disable=SC2086
  if r=$(ssh $SSH_OPTS ${ID_OPTS[@]+"${ID_OPTS[@]}"} -p "$PORT" "$USER_NAME@$HOST" 'echo vpsforge-ok; sudo -n true 2>/dev/null && echo sudo-nopasswd; true' 2>&1); then
    case "$r" in
      *vpsforge-ok*) pass "admin login as $USER_NAME works";;
      *) fail "admin login succeeded but the probe command did not run (forced command or non-standard shell): $(printf '%s' "$r" | head -n 1)";;
    esac
    case "$r" in *sudo-nopasswd*) info "$USER_NAME has passwordless sudo";; *) info "$USER_NAME sudo requires a password (or no sudo)";; esac
  else
    fail "admin login as $USER_NAME FAILED: $(printf '%s' "$r" | tail -n 1)"
  fi
fi

# ------------------------------------------------------------------ ports ---
RISKY=" 2375 2376 3306 5432 5601 5984 6379 7001 8086 9000 9090 9100 9200 9300 11211 15672 27017 28017 "

# Does the name have AAAA records? getent (Linux) answers v4-only names with ::ffff:-mapped
# addresses, which are not IPv6; dig covers macOS, which has no getent.
has_aaaa() {
  local a=""
  if have getent; then a=$(getent ahostsv6 "$1" 2>/dev/null | awk '{print $1}' | grep -vi '^::ffff:' | head -n 1)
  elif have dig; then a=$(dig +short AAAA "$1" 2>/dev/null | grep ':' | head -n 1)
  fi
  [ -n "$a" ]
}

# scan_family FLAG: scan the common ports over one address family (FLAG is "" or "-6").
# Sets: open (list of open ports), scan_err (why the scan is not trustworthy).
scan_family() {
  local flag=$1 raw="" r rc spec p
  open=""; scan_err=""
  if have nmap; then
    # Don't let a failed scan read as "nothing open". With --open, a host without open ports
    # has no "Host:" line at all, so success is judged by the exit code and the
    # "(N host(s) up)" summary: a typo'd name or a rejected option scans 0 hosts.
    for spec in "--top-ports 1000" "-p $PORT"; do
      # shellcheck disable=SC2086
      r=$(nmap $flag -Pn -T4 $spec --open -oG - "$HOST" 2>&1); rc=$?
      if [ "$rc" -ne 0 ] || ! printf '%s\n' "$r" | grep -qE '\([1-9][0-9]* hosts? up\)'; then
        [ -n "$scan_err" ] || scan_err="nmap exit $rc: $(printf '%s\n' "$r" | grep -v '^#' | grep . | head -n 1)"
      fi
      raw="$raw$r
"
    done
    open=$(printf '%s' "$raw" | sed -n 's/.*Ports: //p' | tr ',' '\n' | awk -F/ '$2=="open"{gsub(/ /,"",$1); print $1}' | sort -n | uniq | tr '\n' ' ')
    scan_tool=nmap
  elif have nc; then
    NC_OPTS="-z -w 2"
    # BSD nc on macOS: -w does not bound the connect itself, -G does.
    [ "$(uname -s 2>/dev/null)" = Darwin ] && NC_OPTS="$NC_OPTS -G 2"
    for p in 21 22 23 25 53 80 110 111 135 139 143 443 445 465 587 993 995 1433 1521 2049 2375 2376 3000 3306 3389 \
             5000 5432 5601 5672 5900 5984 6379 6443 7001 8000 8008 8080 8081 8086 8443 8888 9000 9090 9100 9200 9300 \
             10000 11211 15672 27017 "$PORT"; do
      # shellcheck disable=SC2086
      nc $flag $NC_OPTS "$HOST" "$p" >/dev/null 2>&1 && open="$open$p "
    done
    open=$(echo "$open" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')
    scan_tool=nc
    # nc can't tell "closed" from "unreachable": nothing answering at all is suspicious.
    [ -n "${open// /}" ] || scan_err="no probed port answered (host down, wrong name, or everything filtered?)"
  else
    scan_tool=""
  fi
}

expected=" $PORT 80 443 "
if [ "$SCAN" = 1 ]; then
  head_ "OPEN TCP PORTS"
  fam=""; [ "$V6LIT" = 1 ] && fam="-6"
  scan_family "$fam"
  case "$scan_tool" in
    nmap) if [ -n "$scan_err" ]; then fail "port scan failed, results are incomplete ($scan_err)"; else info "scanned top 1000 ports with nmap"; fi ;;
    nc) info "nmap not found; probed common ports with nc (install nmap for a full scan)" ;;
    *) warn "neither nmap nor nc available; port scan skipped" ;;
  esac
  if [ -n "${open// /}" ]; then
    info "open: $open"
    for p in $open; do
      case "$RISKY" in *" $p "*) fail "port $p is reachable from the internet (database/admin/API port). Bind it to localhost or firewall it" ;; esac
    done
    for p in $open; do
      case "$expected$RISKY" in *" $p "*) ;; *) warn "port $p is open: make sure it's intended and documented in SERVER.md" ;; esac
    done
    case " $open " in *" $PORT "*) ;; *) info "SSH port $PORT is not reachable publicly (fine if SSH is VPN-only)";; esac
  elif [ -n "$scan_err" ]; then
    case "$scan_err" in nmap*) ;; *) warn "$scan_err" ;; esac
  elif [ -n "$scan_tool" ]; then
    info "no open TCP ports found"
  fi

  # ufw can be tight on IPv4 and wide open on IPv6: a name with AAAA records gets its own pass.
  if [ -n "$scan_tool" ] && [ "$V6LIT" = 0 ] && has_aaaa "$HOST"; then
    head_ "OPEN TCP PORTS (IPv6)"
    scan_family -6
    if [ -n "${open// /}" ]; then
      info "open (IPv6): $open"
      for p in $open; do
        case "$RISKY" in *" $p "*) fail "port $p is reachable over IPv6 (database/admin/API port). Bind it to localhost or firewall it (ip6tables / ufw IPV6=yes)" ;; esac
      done
      for p in $open; do
        case "$expected$RISKY" in *" $p "*) ;; *) warn "port $p is open over IPv6: make sure it's intended" ;; esac
      done
    elif [ -n "$scan_err" ]; then
      # No IPv6 route from this machine looks the same as a closed server: say it is unverified.
      info "IPv6 scan inconclusive, exposure over IPv6 not verified ($scan_err)"
    else
      info "no open TCP ports found over IPv6"
    fi
  fi
fi

# -------------------------------------------------------------------- ssh ---
if have ssh && [ "$LOGIN" = 1 ]; then
  head_ "SSH AUTH PROBES"
  probe="vpsforge-probe-$$"
  # sshd picks the offered methods for the supplied username, so probe the real admin and root
  # too: a Match User block can leave password auth on for them while the throwaway user sees keys.
  set -- "$probe"
  [ -n "$USER_NAME" ] && set -- "$@" "$USER_NAME"
  [ "$ROOTTEST" = 1 ] && set -- "$@" root
  for who in "$@"; do
    # shellcheck disable=SC2086
    out=$(ssh $SSH_OPTS -o PreferredAuthentications=none -o PubkeyAuthentication=no -p "$PORT" "$who@$HOST" true 2>&1); rc=$?
    methods=$(printf '%s' "$out" | sed -n 's/.*Permission denied (\(.*\))\..*/\1/p' | head -n 1)
    if [ -z "$methods" ]; then
      # Never let an unreachable or reworded server look like "key-only": that is unverified.
      case "$out" in
        *"Permission denied"*) fail "could not verify auth methods for $who (auth protocol, ssh exit $rc): $(printf '%s' "$out" | head -n 1)" ;;
        *) fail "could not verify auth methods for $who (connect-time failure, ssh exit $rc): $(printf '%s' "$out" | head -n 1)" ;;
      esac
    else
      case ",$methods," in
        *password*|*keyboard-interactive*)
          # With real 2FA (AuthenticationMethods publickey,keyboard-interactive) an unauthenticated
          # client is only offered "publickey". Seeing keyboard-interactive here means a password
          # (via PAM) can be enough on its own.
          fail "server offers password-style auth to $who before any key: $methods" ;;
        *) pass "only key-based auth offered to $who: $methods" ;;
      esac
    fi
  done

  if [ "$ROOTTEST" = 1 ]; then
    # Only an explicit authentication rejection counts as "refused". A timeout, a refused
    # connection or a fail2ban ban also make ssh exit 255 and prove nothing.
    # shellcheck disable=SC2086
    rt=$(ssh $SSH_OPTS ${ID_OPTS[@]+"${ID_OPTS[@]}"} -p "$PORT" "root@$HOST" true 2>&1 >/dev/null); rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "root can log in over SSH with your key"
    elif [ "$rc" -eq 255 ] && printf '%s' "$rt" | grep -q 'Permission denied'; then
      pass "root login refused for your key (another key may still work: confirm with 'sudo sshd -T | grep -i permitrootlogin' on the server)"
    else
      warn "could not test root login (ssh exit $rc: $(printf '%s\n' "$rt" | grep . | head -n 1)). Banned by fail2ban, wrong --port, or host down?"
    fi
  fi
  info "the probes count as failed logins in fail2ban unless your IP is in its ignoreip"
fi

# ssh-audit does not need the ssh client, so it also runs with --no-login-tests.
if [ "$SSHAUDIT" = 1 ]; then
  head_ "SSH ALGORITHM AUDIT"
  if have ssh-audit; then
    sa_opts=""
    if ssh-audit --help 2>&1 | grep -q -- '--skip-rate-test'; then sa_opts="--skip-rate-test"; fi
    # shellcheck disable=SC2086
    sa=$(ssh-audit $sa_opts -t 10 -p "$PORT" "$HOST" 2>&1); rc=$?
    nf=$(printf '%s\n' "$sa" | grep -c '\[fail\]'); nw=$(printf '%s\n' "$sa" | grep -c '\[warn\]')
    # ssh-audit 3.x exit codes: 0 good, 1 connection error, 2 warnings, 3 failures
    case $rc in
      0) pass "ssh-audit: no warnings or failures" ;;
      2) warn "ssh-audit: $nw warning(s). Run 'ssh-audit -p $PORT $HOST' for details" ;;
      3) fail "ssh-audit: $nf failure(s), $nw warning(s). Run 'ssh-audit -p $PORT $HOST' for details" ;;
      1) warn "ssh-audit could not connect. If earlier probes worked, your IP is likely banned: from the console or another IP run 'fail2ban-client set sshd unbanip <your-ip>' (and 'set recidive unbanip <your-ip>'), then whitelist it" ;;
      *) warn "ssh-audit returned exit $rc ($nf fail, $nw warn)" ;;
    esac
  else
    warn "ssh-audit requested but not installed (pipx install ssh-audit)"
  fi
fi

# ---------------------------------------------------------------- domain ---
if [ -n "$DOMAIN" ]; then
  head_ "WEB: $DOMAIN"
  dh=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z'); dh=${dh%.}
  TLS_SKIP=0
  # s_client can hang on a filtered port; bound it where timeout (GNU) or gtimeout (macOS coreutils) exists.
  TO=()
  if have timeout; then TO=(timeout 10); elif have gtimeout; then TO=(gtimeout 10); fi
  if have curl; then
    r=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "http://$DOMAIN/"); crc=$?
    code=${r%% *}; loc=${r#* }
    if [ "$crc" -ne 0 ]; then
      case "$crc" in
        6) info "http://$DOMAIN does not resolve; check DNS" ;;
        7) info "port 80 not reachable (fine with HSTS-preloaded or Tunnel setups)" ;;
        28) info "http://$DOMAIN timed out" ;;
        *) info "http://$DOMAIN is unreachable (curl exit $crc)" ;;
      esac
    else
      case "$code" in
        301|302|303|307|308)
          lloc=$(printf '%s' "$loc" | tr 'A-Z' 'a-z')
          case "$lloc" in
            https://*)
              rh=$(url_host "$lloc")
              if [ "$rh" = "$dh" ] || [ "$rh" = "www.$dh" ]; then pass "http redirects to https ($code)"
              else warn "http redirects to another host: $loc"; fi ;;
            *) warn "http redirects, but not to https: $loc" ;;
          esac ;;
        000) info "port 80 not reachable (fine with HSTS-preloaded or Tunnel setups)" ;;
        *) warn "http answers $code without redirecting to https" ;;
      esac
    fi
    # GET with redirects, keeping only the final response: HEAD and 3xx pages often lack app headers.
    hraw=$(curl -sS -D - -o /dev/null -L --max-redirs 5 --max-time 10 "https://$DOMAIN/" 2>&1); hrc=$?
    hdrs=$(printf '%s\n' "$hraw" | tr -d '\r' | awk '/^HTTP\//{b=""} {b=b $0 "\n"} END{printf "%s", b}')
    # Resolve failure, refused connection or timeout: the TLS probes below would only hang or repeat it.
    case "$hrc" in 6|7|28) TLS_SKIP=1 ;; esac
    if printf '%s' "$hdrs" | grep -qi '^HTTP/'; then
      lc=$(printf '%s' "$hdrs" | tr 'A-Z' 'a-z')
      for h in strict-transport-security x-content-type-options referrer-policy; do
        if printf '%s\n' "$lc" | grep -q "^$h:"; then pass "header $h present"; else warn "header $h missing"; fi
      done
      if printf '%s\n' "$lc" | grep -q '^content-security-policy'; then pass "content-security-policy present"; else info "no content-security-policy (write one for the app; start Report-Only)"; fi
      srv=$(printf '%s\n' "$hdrs" | grep -i '^server:' | head -n 1 | cut -d' ' -f2-)
      case "$srv" in *[0-9]*) warn "Server header leaks a version: $srv";; "") pass "no Server header";; *) info "Server: $srv";; esac
    else
      fail "https://$DOMAIN not reachable: $(printf '%s' "$hdrs" | head -n 1)"
    fi
  fi
  if [ "$TLS_SKIP" = 1 ]; then
    info "TLS certificate and legacy-protocol checks skipped: https://$DOMAIN is not reachable"
  elif have openssl; then
    cert=$(${TO[@]+"${TO[@]}"} openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 2>/dev/null)
    if [ -n "$cert" ]; then
      end=$(printf '%s\n' "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if printf '%s\n' "$cert" | openssl x509 -noout -checkend 1209600 >/dev/null 2>&1; then pass "certificate valid until $end"
      else fail "certificate expires within 14 days ($end)"; fi
    else
      warn "could not fetch the TLS certificate"
    fi
    # OpenSSL 1.1+/3 refuses TLS 1.0/1.1 client-side at the default security level, so lower
    # it. LibreSSL (macOS) and OpenSSL 1.0 reject the token: fall back to plain DEFAULT.
    legacy_cipher='DEFAULT:@SECLEVEL=0'
    openssl ciphers "$legacy_cipher" >/dev/null 2>&1 || legacy_cipher='DEFAULT'
    for v in tls1 tls1_1; do
      if openssl s_client -help 2>&1 | grep -q -- "-$v "; then
        r=$(${TO[@]+"${TO[@]}"} openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" "-$v" -cipher "$legacy_cipher" </dev/null 2>&1)
        # A refused handshake still prints "Protocol : TLSv1" and "Cipher : 0000" (OpenSSL 3.x), so
        # the protocol line proves nothing: only a real negotiated cipher counts as "accepted".
        cip=$(printf '%s\n' "$r" | sed -n 's/.*Cipher is \([^ ,]*\).*/\1/p; s/^ *Cipher *: *\([^ ]*\).*/\1/p' | grep -vE '^(\(NONE\)|0+)$' | head -n 1)
        if [ -n "$cip" ]; then
          warn "legacy $v accepted ($cip)"
        elif printf '%s' "$r" | grep -qiE 'no protocols available|unsupported protocol|no ciphers available|error setting cipher|no cipher match|unknown cipher|cipher list|@SECLEVEL'; then
          info "$v: your local openssl can't test it (inconclusive)"
        elif printf '%s' "$r" | grep -qi 'alert'; then
          pass "$v refused by the server"
        else
          info "$v: no clear answer from the server (inconclusive)"
        fi
      fi
    done
  fi
fi

printf '\n%sResult:%s %d FAIL, %d WARN\n' "$B" "$N" "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
