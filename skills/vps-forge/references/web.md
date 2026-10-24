# Web profile: reverse proxy and TLS

## Contents
- Caddy (default)
- nginx + certbot (alternative)
- Security headers and HSTS rollout
- Behind Cloudflare
- Verify

## Caddy (default)

First check what already serves the web: `ss -H -tlnp 'sport = :80 or sport = :443'`. If `nginx` or `apache2` (or a containerised proxy) owns 80/443, **work with it** instead of installing Caddy: Caddy would fail to bind, and stopping the existing server takes live sites down. Add the new site to that server (the nginx section below; for Apache, a vhost plus `certbot --apache`), and keep the same headers and HSTS rollout.

Caddy obtains and renews certificates by itself, redirects HTTP to HTTPS, serves HTTP/2 and HTTP/3, and has a tiny config. Install it from the official repo; check https://caddyserver.com/docs/install#debian-ubuntu-raspbian for the current commands.

Prerequisites for automatic HTTPS: the domain's A/AAAA records point at the server, ports 80 and 443 are open, and (if behind Cloudflare) the SSL mode is **Full (strict)**.

Start from `assets/caddy/Caddyfile`:
- A global `email` for ACME expiry notices.
- A `(hardening)` snippet with security headers, `-Server`, and `encode zstd gzip`.
- One site block per domain that does `reverse_proxy 127.0.0.1:<port>`.
- `www` → apex redirect. Delete that block when `www` has no DNS record: Caddy would keep failing the certificate order for a name that doesn't resolve (it backs off and moves to the staging CA, so Let's Encrypt limits are not at risk, but the log fills with errors).

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
journalctl -u caddy -n 50 --no-pager     # watch the certificate get issued
```
Caddy's state (certificates and account keys) lives in `/var/lib/caddy`. Include it in backups to avoid rate limits after a rebuild.

## nginx + certbot (alternative)

Use nginx when the user already knows it or needs its specific modules.
```bash
$APT install nginx certbot python3-certbot-nginx
certbot --nginx -d example.com -d www.example.com --redirect -m <email> --agree-tos -n
certbot renew --dry-run
systemctl list-timers certbot.timer   # renewal must be scheduled
```
Hardening in `/etc/nginx/conf.d/00-vps-forge.conf`:
```nginx
server_tokens off;
client_max_body_size 20m;
```
A default server that refuses requests for unknown hosts and bare-IP scans:
```nginx
server { listen 80 default_server; listen [::]:80 default_server; return 444; }
```
For TLS settings, use Mozilla's "intermediate" profile (ssl-config.mozilla.org). certbot's `options-ssl-nginx.conf` is already close to it. Test with `nginx -t && systemctl reload nginx`.

## Security headers and HSTS rollout

Headers to set on HTML responses: `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN` (or CSP `frame-ancestors`), `Permissions-Policy` that disables what isn't used, and a `Content-Security-Policy` written for the actual app. Don't invent a CSP blind, because it breaks sites. Suggest `Content-Security-Policy-Report-Only` first.

**HSTS** is a one-way door: once browsers have cached it, the site can't go back to HTTP for `max-age`. Roll it out in stages:
1. `max-age=300` and confirm everything works over HTTPS.
2. `max-age=31536000` (1 year).
3. Add `includeSubDomains` only if **every** subdomain is HTTPS; add `preload` only if the user explicitly wants list submission.

The Caddyfile template ships at stage 1 (5 minutes) without `includeSubDomains`. Raise it to stage 2 once you've seen the site work over HTTPS, and tell the user what stage 2 means: for a year, browsers that visited will refuse plain HTTP.

## Behind Cloudflare

- SSL mode **Full (strict)**. "Flexible" causes redirect loops and plaintext between Cloudflare and the origin.
- Real client IPs: Caddy uses `servers { trusted_proxies static <cloudflare ranges> }` in the global options, plus `client_ip_headers CF-Connecting-IP`. nginx uses `set_real_ip_from <range>;` per range plus `real_ip_header CF-Connecting-IP;`. Without this, fail2ban, CrowdSec and rate limits act on Cloudflare's IPs.
- Lock the origin down: see firewall.md (allowlist or Tunnel).
  - When the proxy runs in a container (Docker publishes 80/443 through FORWARD, so plain `ufw allow` rules don't filter it), run the sync with `CF_MODE=route` (`systemctl edit ufw-cloudflare-sync.service`, `[Service]` `Environment=CF_MODE=route`). It manages `ufw route allow ... comment cf-sync-route` rules and needs ufw-docker or other DOCKER-USER filtering to have any effect. Rules from the other mode (`cf-sync`) are not touched: remove them by hand when switching.

## Verify

```bash
curl -sSI http://example.com | head -n 3             # 301/308 → https
curl -sSI https://example.com | grep -iE 'strict-transport|x-content-type|referrer-policy|server'
```
External: `bash scripts/external-check.sh <host> --domain example.com` checks the redirect, the headers, certificate expiry and the TLS versions offered. For depth, testssl.sh (`testssl.sh example.com`), https://securityheaders.com and https://www.ssllabs.com/ssltest/ are good targets: A or A+.
