#!/usr/bin/env bash
# ufw-cloudflare-sync.sh: allow web ports only from Cloudflare's published ranges.
# New ranges are added before stale ones are removed, so there is no window without access.
# If the download looks wrong, nothing is changed. Idempotent: ufw skips rules that exist.
# Remove the generic "allow 80,443" rule yourself once this works.
#   CF_PORTS=80,443 (default)
#   CF_MODE=allow (default)  host proxy (Caddy/nginx on the server): `ufw allow ... comment cf-sync`
#   CF_MODE=route            containerised proxy whose ports Docker publishes: Docker's traffic goes
#                            through FORWARD, so these are `ufw route allow ... comment cf-sync-route`
#                            rules. They only take effect together with ufw-docker or other
#                            DOCKER-USER filtering (firewall.md); the ports are the CONTAINER ports.
# The two modes use different tags and never touch each other's rules. Part of vps-forge (MIT).
set -euo pipefail
export LC_ALL=C
PORTS=${CF_PORTS:-80,443}
MODE=${CF_MODE:-allow}
case "$MODE" in
  allow) TAG=cf-sync;       UFW_ADD=(ufw allow) ;;
  route) TAG=cf-sync-route; UFW_ADD=(ufw route allow) ;;
  *) echo "CF_MODE must be allow or route (got: $MODE)" >&2; exit 2 ;;
esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

curl -fsS --max-time 20 --retry 3 https://www.cloudflare.com/ips-v4 -o "$tmp/v4"
curl -fsS --max-time 20 --retry 3 https://www.cloudflare.com/ips-v6 -o "$tmp/v6"
grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$tmp/v4" > "$tmp/ok4" || true
grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$tmp/v6" > "$tmp/ok6" || true
n4=$(wc -l < "$tmp/ok4"); n6=$(wc -l < "$tmp/ok6")
if (( n4 < 5 || n6 < 3 )); then
  echo "unexpected range list (v4=$n4, v6=$n6); leaving rules unchanged" >&2
  exit 1
fi
if grep -qiE '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  sort -u "$tmp/ok4" "$tmp/ok6" > "$tmp/want"
else
  echo "ufw IPv6 is disabled: syncing IPv4 ranges only" >&2
  sort -u "$tmp/ok4" > "$tmp/want"
fi

# add missing (ufw skips rules that already exist)
errors=0
while read -r net; do
  "${UFW_ADD[@]}" proto tcp from "$net" to any port "$PORTS" comment "$TAG" >/dev/null || { echo "failed to add $net" >&2; errors=$((errors+1)); }
done < "$tmp/want"
if (( errors > 0 )); then
  echo "$errors rule(s) could not be added; stale rules left in place" >&2
  exit 1
fi

# remove stale rules of this mode, highest number first. The tag must end the line: "cf-sync"
# is a prefix of "cf-sync-route". Route rules read "ALLOW FWD", allow rules "ALLOW IN".
ufw status numbered | grep -E "# ${TAG}[[:space:]]*\$" | while read -r line; do
  num=$(sed -nE 's/^\[ *([0-9]+)\].*/\1/p' <<<"$line")
  src=$(awk '{for(i=1;i<=NF;i++) if($i=="IN"||$i=="FWD"){print $(i+1); exit}}' <<<"${line#*]}")
  [[ -n "$num" && -n "$src" ]] || continue
  grep -qxF "$src" "$tmp/want" || echo "$num"
done | sort -rn | while read -r num; do
  ufw --force delete "$num" >/dev/null
done

echo "$TAG: $(ufw status | grep -cE "# ${TAG}[[:space:]]*\$" || true) rules for ports $PORTS"
