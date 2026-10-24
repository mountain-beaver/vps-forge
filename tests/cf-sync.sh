#!/usr/bin/env bash
# ufw-cloudflare-sync.sh against a stateful stub ufw and a stub curl, in both modes (allow, route).
# The script is copied with /etc/default/ufw rewritten into a temp dir. No root needed.
# tests/fixtures/ufw-status-route.txt is real `ufw status numbered` output (ufw 0.36.2): route
# rules read "ALLOW FWD", allow rules "ALLOW IN", and cf-sync is a prefix of cf-sync-route.
set -euo pipefail
cd "$(dirname "$0")/.."
SKILL=skills/vps-forge
FIX=$PWD/tests/fixtures
fail=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
sed "s#/etc/default/ufw#$T/ufw-default#g" "$SKILL/assets/firewall/ufw-cloudflare-sync.sh" > "$T/sync.sh"

cat > "$T/bin/curl" <<STUB
#!/bin/sh
# curl -fsS ... URL -o FILE
for a in "\$@"; do case "\$a" in https://*) url=\$a ;; esac; done
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
[ -f "$T/curl.fail" ] && exit 22
case "\$url" in *ips-v4) cat "$T/ips-v4" > "\$out" ;; *) cat "$T/ips-v6" > "\$out" ;; esac
STUB
# ufw: rules live in $T/rules as "TAG|KIND|NET" lines (KIND = IN or FWD); `status numbered` prints
# them in real ufw's format; adding an existing rule is a no-op, like ufw.
cat > "$T/bin/ufw" <<STUB
#!/bin/sh
R="$T/rules"; touch "\$R"
echo "ufw \$*" >> "$T/ufw.log"
kind=IN
[ "\$1" = route ] && { kind=FWD; shift; }
case "\$1" in
  allow)
    shift; net=""; tag=""
    while [ \$# -gt 0 ]; do case "\$1" in from) net=\$2; shift ;; comment) tag=\$2; shift ;; esac; shift; done
    grep -qxF "\$tag|\$kind|\$net" "\$R" || echo "\$tag|\$kind|\$net" >> "\$R"
    echo "Rule added" ;;
  status)
    echo "Status: active"; echo
    n=0
    while IFS='|' read -r tag k net; do
      n=\$((n+1)); printf '[%2d] 80,443/tcp                 ALLOW %-4s %-18s # %s\n' "\$n" "\$k" "\$net" "\$tag"
    done < "\$R" ;;
  --force)
    n=\$3; sed -i "\${n}d" "\$R"; echo "Rule deleted" ;;
esac
STUB
chmod +x "$T"/bin/*

mklists() { # v4 list with 5 entries incl. 173.245.48.0/20, v6 with 3
  printf '173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n' > "$T/ips-v4"
  printf '2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n' > "$T/ips-v6"
}
run() { # mode [extra env]
  : > "$T/ufw.log"
  CF_MODE=$1 PATH="$T/bin:$PATH" bash "$T/sync.sh" >"$T/out.log" 2>&1 && rc=0 || rc=$?
}
nrules() { grep -c "^$1|" "$T/rules" || true; }

mklists; echo 'IPV6=yes' > "$T/ufw-default"
rm -f "$T/rules"; : > "$T/rules"
run allow
if [[ $rc -eq 0 && $(nrules cf-sync) -eq 8 && $(grep -c '^cf-sync|IN|' "$T/rules") -eq 8 ]] && ! grep -q 'ufw route' "$T/ufw.log"; then
  ok "allow mode: 5 v4 + 3 v6 rules as 'ufw allow ... cf-sync'"
else
  bad "allow mode (rc=$rc): $(cat "$T/rules" | tr '\n' ' ') / $(tail -n 2 "$T/out.log")"
fi
before=$(cat "$T/rules")
run allow
if [[ $rc -eq 0 && "$(cat "$T/rules")" == "$before" ]]; then ok "allow mode is idempotent"; else bad "allow mode, second run changed rules"; fi

rm -f "$T/rules"; : > "$T/rules"
run route
if [[ $rc -eq 0 && $(nrules cf-sync-route) -eq 8 && $(grep -c '^cf-sync-route|FWD|' "$T/rules") -eq 8 ]] && grep -q '^ufw route allow proto tcp from 173.245.48.0/20 to any port 80,443 comment cf-sync-route' "$T/ufw.log"; then
  ok "route mode: 8 'ufw route allow ... cf-sync-route' rules"
else
  bad "route mode (rc=$rc): $(tr '\n' ' ' < "$T/rules") / $(tail -n 2 "$T/out.log")"
fi
before=$(cat "$T/rules")
run route
if [[ $rc -eq 0 && "$(cat "$T/rules")" == "$before" ]]; then ok "route mode is idempotent"; else bad "route mode, second run changed rules"; fi

# stale ranges: a range Cloudflare no longer lists disappears, in its own mode only
{ cat "$T/rules"; echo 'cf-sync-route|FWD|198.51.100.0/24'; echo 'cf-sync|IN|203.0.113.0/24'; } > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
run route
if [[ $rc -eq 0 && $(nrules cf-sync-route) -eq 8 ]] && ! grep -q '198.51.100.0/24' "$T/rules" && grep -q '^cf-sync|IN|203.0.113.0/24' "$T/rules"; then
  ok "route mode removes a stale range and leaves cf-sync (allow) rules alone"
else
  bad "route stale (rc=$rc): $(tr '\n' ' ' < "$T/rules")"
fi
run allow
if [[ $rc -eq 0 ]] && ! grep -q '203.0.113.0/24' "$T/rules" && [[ $(nrules cf-sync-route) -eq 8 ]]; then
  ok "allow mode removes its stale range and does not delete cf-sync-route rules (tag prefix)"
else
  bad "allow stale (rc=$rc): $(tr '\n' ' ' < "$T/rules")"
fi

# IPV6=no: only IPv4 ranges, and existing v6 rules go away
echo 'IPV6=no' > "$T/ufw-default"
run route
if [[ $rc -eq 0 && $(nrules cf-sync-route) -eq 5 ]] && ! grep '^cf-sync-route|' "$T/rules" | grep -q ':'; then
  ok "route mode with IPV6=no keeps IPv4 ranges only and removes the v6 rules"
else
  bad "IPV6=no (rc=$rc): $(tr '\n' ' ' < "$T/rules")"
fi
echo 'IPV6=yes' > "$T/ufw-default"

# a broken list changes nothing
for mode in allow route; do
  before=$(cat "$T/rules")
  printf '<html>blocked</html>\n' > "$T/ips-v4"
  run "$mode"; [[ $rc -ne 0 && "$(cat "$T/rules")" == "$before" ]] && ! grep -q '^ufw ' "$T/ufw.log" && ok "$mode mode: a broken list leaves the rules unchanged" || bad "$mode broken list (rc=$rc)"
  mklists
  touch "$T/curl.fail"; run "$mode"
  [[ $rc -ne 0 && "$(cat "$T/rules")" == "$before" ]] && ok "$mode mode: a failed download leaves the rules unchanged" || bad "$mode failed download (rc=$rc)"
  rm -f "$T/curl.fail"
done
run bogus
[[ $rc -eq 2 ]] && ok "an unknown CF_MODE is rejected" || bad "unknown CF_MODE (rc=$rc)"

# parsing against REAL `ufw status numbered` output
cat > "$T/bin/ufw" <<STUB
#!/bin/sh
echo "ufw \$*" >> "$T/ufw.log"
case "\$1" in status) cat "$FIX/ufw-status-route.txt" ;; *) echo "Rule added" ;; esac
STUB
printf '173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n' > "$T/ips-v4"
echo 'IPV6=no' > "$T/ufw-default"
run route
if [[ $rc -eq 0 ]] && grep -qx 'ufw --force delete 3' "$T/ufw.log" && [[ $(grep -c 'ufw --force delete' "$T/ufw.log") -eq 1 ]]; then
  ok "real ufw output: route mode deletes only the stale FWD rule (#3), not the cf-sync IN rule"
else
  bad "real output, route (rc=$rc): $(grep delete "$T/ufw.log" | tr '\n' ' ')"
fi
run allow
if [[ $rc -eq 0 ]] && grep -qx 'ufw --force delete 2' "$T/ufw.log" && [[ $(grep -c 'ufw --force delete' "$T/ufw.log") -eq 1 ]]; then
  ok "real ufw output: allow mode deletes only the stale IN rule (#2), not the route rules"
else
  bad "real output, allow (rc=$rc): $(grep delete "$T/ufw.log" | tr '\n' ' ')"
fi

echo
if (( fail )); then echo "CF-SYNC TESTS FAILED"; exit 1; fi
echo "CF-SYNC TESTS PASSED"
