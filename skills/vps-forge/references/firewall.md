# Firewall and brute-force defence

## Contents
- ufw baseline
- IPv6
- Cloudflare-only web ports
- Docker bypasses ufw
- Provider firewall (second layer)
- The admin's IP
- fail2ban
- CrowdSec (alternative)
- Egress filtering (paranoid)

## ufw baseline

Before enabling, compare against what is actually listening, so you don't silently break a running service on an existing box:
```bash
ss -H -tulpn | awk '{print $1, $5, $7}'
```
Then, inside a deadman window:
```bash
vps-forge-deadman arm 5
# fail2ban installed? The admin's IP must already be in its ignoreip (see fail2ban below)
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed            # keep "allow routed" only for VPN gateways (vpn.md)
ufw prepend allow from <admin-ip> to any port <ssh-port> proto tcp comment 'admin: not rate-limited'
ufw limit <ssh-port>/tcp comment 'ssh'  # limit = 6 new conns / 30s per IP
ufw allow 80,443/tcp comment 'web' # web profile only
ufw allow 443/udp comment 'http3'  # only if Caddy/nginx serves HTTP/3
ufw --force enable
ufw status verbose
# test and disarm from a fresh connection (ssh.md "Test and disarm"); the multiplexed master skips ufw
```
- The admin rule comes first because ufw matches in order: `limit` knows nothing about fail2ban's `ignoreip`, and verification runs (`external-check.sh`, test logins with `ControlPath=none`) easily open 6 connections in 30 s. With key-only SSH the exemption costs nothing.
- Always use `ufw prepend` for it. `ufw allow` appends, and behind an existing `limit` rule it never matches. `prepend` puts the v4 rule first and the v6 rule before the v6 `limit`. `ufw insert 1` fails for IPv6.
- `<admin-ip>` is the validated `ADMIN_IP` from "The admin's IP" below, never an empty string: `ufw allow from  to …` fails, and an empty `ignoreip` entry protects nobody.
- `ufw limit` is fine with SSH multiplexing (ControlMaster). Tools that open many parallel connections (Ansible without pipelining, some CI) can trip it. In that case use `allow` and let fail2ban do the work.
- Add a `comment` to every rule. SERVER.md is built from `ufw status`.
- Admin panels, databases, Redis, metrics: **never** open these to the world. Bind them to `127.0.0.1` and reach them via an SSH tunnel or the VPN interface (`ufw allow in on wg0 to any port 5432` / `ufw allow in on tailscale0`).

## IPv6

`/etc/default/ufw` must have `IPV6=yes` (the default). If the box has a public IPv6 address and ufw IPv6 is off, everything is wide open on v6. `audit.sh` checks this. Verify with `ip -6 addr show scope global` and `ufw status` (each rule should appear with `(v6)`).

## Cloudflare-only web ports

If the domain is proxied through Cloudflare (orange cloud), direct hits on the origin IP bypass the WAF and rate limiting. Options, from best to simplest:

1. **Cloudflare Tunnel** (`cloudflared`): the server dials out, and 80/443 stay closed entirely. This is the best option at the paranoid level.
2. **Allowlist Cloudflare ranges:** install `assets/firewall/ufw-cloudflare-sync.sh` to `/usr/local/sbin/` with its weekly timer (`assets/firewall/ufw-cloudflare-sync.{service,timer}`). It fetches `https://www.cloudflare.com/ips-v4` and `/ips-v6`, sanity-checks them, and replaces the rules tagged `cf-sync`. Remove the generic `allow 80,443/tcp` rule afterwards, and the `443/udp` rule too.
   - **Reverse proxy in Docker with published 80/443?** Then ufw `allow` rules don't apply at all: Docker DNATs the traffic, so it never passes INPUT (see "Docker bypasses ufw"), and the origin stays open to everyone. Either run the proxy with `network_mode: host`, so the INPUT rules apply, or use the sync script's route mode (`CF_MODE=route`), which manages `ufw route allow … comment 'cf-sync-route'` rules for the forwarded traffic.
3. Also configure **Authenticated Origin Pulls** (mTLS) so that only Cloudflare can present a valid client certificate.

Real client IPs: configure the proxy's trusted proxies to the same ranges (see web.md), otherwise logs and fail2ban only ever see Cloudflare IPs.

## Docker bypasses ufw

Docker writes its own iptables/nftables rules for published ports, and they are evaluated **before** ufw's. `-p 8080:8080` is open to the internet even if `ufw status` doesn't show it. This is one of the most common real-world exposures. In order of preference:

1. **Publish to localhost only** and put a reverse proxy in front: `ports: ["127.0.0.1:8080:8080"]`. Services that only talk to each other need no `ports:` at all; use a compose network.
2. **Filter in the DOCKER-USER chain** when a container must be reachable directly. The maintained helper is [`ufw-docker`](https://github.com/chaifeng/ufw-docker). Show the user what it does, get their OK to download it, review it, then run `ufw-docker install && systemctl restart ufw`. After that, expose with `ufw route allow proto tcp from any to any port 8080`.
3. Do **not** set `"iptables": false` in daemon.json. It breaks container networking in subtle ways.

`audit.sh` reports any container port published on `0.0.0.0` or `[::]` as FAIL.

## Provider firewall (second layer, hardened+)

Hetzner Cloud Firewall, DigitalOcean Cloud Firewall, Vultr Firewall, AWS Security Groups and similar filter traffic **before** it reaches the VM. Mirror the ufw policy there (SSH, 80/443, VPN port). Benefits: Docker can't bypass it, it survives a broken ufw config, and it absorbs scan noise. Tell the user exactly which rules to create in the panel. If they use a provider API/CLI (`hcloud`), you can do it from their machine with their consent. Before an SSH port change, the new port must be open here first (ssh.md).

## The admin's IP

```bash
ADMIN_IP=$(sudo vps-forge-deadman client-ip)   # without sudo when root
[[ $ADMIN_IP =~ ^[0-9A-Fa-f:.]+$ ]] || { echo "no admin IP: stop"; exit 1; }
```
`${SSH_CLIENT%% *}` is empty under sudo (`env_reset`), on every supported distro. `client-ip` finds the address of the calling SSH client even through sudo, and exits 1 when there is none. Stop if the result is empty or not an IP, before writing any file.

**Is it really the user's IP?** It's the address *this session* comes from. If you aren't running on the user's own machine (a cloud sandbox, CI, a jump host), it's your address, not theirs. Whitelist it anyway, so your own tests don't ban you, but mark it: a comment line `# agent session <date>: <ip>` right above `ignoreip`, and `comment 'agent session <date>'` on the ufw rule. Ask the user for their real IP or range and add that too. Remove the agent entries in phase 12 (ssh.md "Hand-off cleanup").

## fail2ban

`assets/fail2ban/vps-forge.local` → `/etc/fail2ban/jail.d/vps-forge.local`:
```ini
[DEFAULT]
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 <admin-ip>

[sshd]
enabled = true
port = <ssh-port>
mode = normal

[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
banaction = nftables-multiport
port = <ssh-port>
bantime = 1d
findtime = 1d
maxretry = 5
```
- Set both `port` lines to the real SSH port. Change them again whenever the SSH port moves (ssh.md). `audit.sh` warns when the jail and sshd disagree.
- Set `<admin-ip>` to `ADMIN_IP` (above) **before fail2ban starts for the first time** (see "Start order"). If that is an IPv6 address, whitelist its `/64`: privacy extensions rotate the low bits. If the user's machine has both IPv4 and IPv6, ask for (or look up) the other family's address as well, since `external-check.sh` may connect over either one.
- `mode = normal` is enough on a key-only box with `AllowGroups`: scanners show up as `Invalid user` or `not allowed because none of user's groups`, and both count. `aggressive` also counts the surplus keys a real user's agent offers.
- recidive bans repeat offenders from SSH for a day; bans still grow up to a week (`bantime.increment`). An all-ports recidive (`banaction = %(banaction_allports)s`) suits only boxes without a public website (worker, vpn): on a web server it locks everyone behind the same CGNAT address out of the site.
- `backend = systemd` needs `python3-systemd`. Debian 12+ has no `/var/log/auth.log`, so the default file backend finds nothing and fail2ban may refuse to start.
- The nftables actions keep bans in their own table (`f2b-table`), separate from ufw. `ufw status` stays clean.
- Debian 13 / OpenSSH 9.8+ logs from `sshd-session`. Debian's own fail2ban package (1.1.0-6 and later) carries the fix. A stock upstream 1.1.0 (pip, older backports) does not match `sshd-session`, so verify detection as described next.

**Start order.** Debian 13 and Ubuntu 24.04 start fail2ban the moment it is installed, with the stock sshd jail and no admin IP. So on a fresh box (base.md, phase 2): `systemctl mask fail2ban`, write `vps-forge.local` with the admin IP and SSH port filled in, and only then run the big `apt-get install`. In phase 5:
```bash
fail2ban-client -t && systemctl unmask fail2ban && systemctl enable --now fail2ban
fail2ban-client get sshd ignoreip; fail2ban-client get recidive ignoreip   # both list the admin IP
```
If fail2ban was already installed and running (audit mode, an existing server), don't mask it. Write the jail with `ignoreip` first, then `fail2ban-client -t && systemctl restart fail2ban`, and unban the admin IP if it is already banned. The `get … ignoreip` check also catches another `jail.d/*.local` that sorts later and overrides yours.

**Prove it works.** Two checks, neither of them a login from the server itself: fail2ban's default `ignoreself = true` ignores the server's own addresses, so such a probe always shows `Total failed 0`.
- **Detection:** `fail2ban-client status sshd` shows the jail and its journal match. `fail2ban-regex systemd-journal sshd` runs the filter over the journal and ignores `ignoreip`, so the failed test logins from phase 3 (root refused, password refused) already show up as `matched`. On Ubuntu 22.04 with `/var/log/auth.log`, use `fail2ban-regex /var/log/auth.log sshd`. `0 matched` while the journal does hold failed logins means the jail is blind; see troubleshooting.md.
- **Action:** `fail2ban-client set sshd banip 192.0.2.250`, then `nft list ruleset | grep 192.0.2.250` (or `iptables -S | grep 192.0.2.250`) shows the ban, then `fail2ban-client set sshd unbanip 192.0.2.250`.

`Total failed 0` in `status sshd` is normal right after setup, and also on a moved port, VPN-only SSH or an allowlisted port: scanners barely reach those. Don't "fix" a jail that passes both checks.

**Don't ban the user.** Hardening means test logins that are *meant* to fail: root refused, passwords refused, the old port closed. With `maxretry = 5` and `findtime = 10m`, a handful of them bans the user's IP. fail2ban's nftables rule then drops all traffic to the SSH port from that IP, which kills the open session too, and the deadman doesn't touch fail2ban. Two details make a runtime `fail2ban-client set sshd addignoreip` too weak:
- When fail2ban starts, it re-reads the last `findtime` of the journal. Failed test logins made *before* fail2ban was even installed ban the user the moment it starts, before any runtime command can run.
- A runtime whitelist is lost on every `systemctl restart fail2ban`, and `delignoreip` exposes the next failures again.

So the admin's IP goes into `ignoreip` in `/etc/fail2ban/jail.d/vps-forge.local` before the first start, and it stays there. With key-only SSH, exempting one address from fail2ban costs nothing; password guessing from it is pointless anyway. Record it in `SERVER.md`. If the user later connects from a new address for another round of changes, update every place before testing: add it to `ignoreip` and `systemctl reload fail2ban`, to `PerSourcePenaltyExemptList` if you set one (ssh.md), and in a deadman window `ufw prepend allow from <new-ip> to any port <ssh-port> proto tcp comment 'admin'`. Delete the old address's rule if the user no longer uses it. Unban the new address if it is already banned: `fail2ban-client set sshd unbanip <ip>`.

OpenSSH 9.8+ (Debian 13, Ubuntu 26.04) adds its own `PerSourcePenalties`: after a few failed logins, sshd refuses that address for 15 s up to 10 min. It expires by itself, so wait instead of retrying in a loop. `ufw limit` is per-IP rate limiting, not a ban: more than 6 new connections in 30 s are dropped for a while. Pause between connection loops instead of hammering the port.

If a ban happens anyway: from the console run `fail2ban-client set sshd unbanip <ip>` (and `set recidive unbanip <ip>`). Repeated bans feed `recidive`, which blocks SSH for a day, and longer for repeat offenders.

Useful commands: `fail2ban-client get sshd banip --with-time` and `fail2ban-client set sshd unbanip <ip>`.

## CrowdSec (alternative, paranoid)

CrowdSec parses logs like fail2ban, but it also shares and receives community blocklists and ships scenarios for nginx, Caddy, WordPress and others. Use it **instead of** fail2ban, not alongside it, on the same logs.
```bash
# their signed apt repository (the same one their install script adds), set up explicitly
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey | gpg --dearmor -o /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main' > /etc/apt/sources.list.d/crowdsec_crowdsec.list
apt-get update && apt-get install -y crowdsec crowdsec-firewall-bouncer-nftables
cscli collections install crowdsecurity/linux crowdsecurity/sshd   # + crowdsecurity/caddy or nginx
cscli metrics; cscli decisions list
```

## Egress filtering (paranoid, rarely worth it)

`ufw default deny outgoing` stops a compromised process from phoning home, but it breaks updates, ACME, DNS, NTP, webhooks and backups unless every destination is inventoried. Offer it only for single-purpose boxes with a known, small set of destinations. Allow at least 53/udp+tcp, 123/udp, 80/443/tcp and the backup endpoint, and test with the deadman armed.
