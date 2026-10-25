# Deploy panels and tools: Coolify, Dokploy, CapRover, Kamal, Dokku

## Contents
- Detect them in recon
- What changes when one is there
- Per tool
- "Harden first, then install Coolify"
- What not to do

These tools own Docker, the reverse proxy and often root's SSH key. The hardened defaults elsewhere in this skill assume nobody else does, and several of them break a panel silently: the next deploy fails and the user blames the hardening. Read this file whenever one of them is installed or the user says they will install one.

## Detect them in recon

```bash
docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -iE 'coolify|dokploy|captain|caprover|kamal-proxy'
ls -d /data/coolify /etc/dokploy /captain /home/dokku 2>/dev/null; command -v dokku
ls -d /root/.kamal /home/*/.kamal 2>/dev/null
ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null   # a key the user doesn't recognise may be the panel's own
```

Kamal runs from the user's laptop or CI, so the server may show nothing until the first deploy: ask "do you deploy with Kamal, Coolify, Dokploy or CapRover?" in intake whenever the profile is `docker` or `web`.

## What changes when one is there

1. **Root stays reachable by key.** Coolify (including its own host), Dokploy and CapRover on the servers they manage, and Kamal by default log in as `root`. Use `PermitRootLogin prohibit-password`, not `no`, and **add root to `sshusers`** (`usermod -aG sshusers root`), because `AllowGroups sshusers` refuses root otherwise. Never remove a root key you can't attribute without asking: it is often the panel's. Say all this in SERVER.md and the final report.
2. **The panel's own SSH must not be banned or rate-limited.** Coolify reaches its own host from its container over a Docker network, so the source address is that network, not the internet. Exempt exactly that one network, never a whole address pool: Coolify's installer sets the pool to `10.0.0.0/8`, which also covers provider private networks such as Hetzner's. Find the subnet and its bridge with `docker network inspect coolify -f '{{range .IPAM.Config}}{{.Subnet}}{{end}} br-{{printf "%.12s" .Id}}'`. Then, before fail2ban starts and ahead of any ufw `limit` rule, add that subnet to fail2ban's `ignoreip` and allow it on that bridge only: `ufw allow in on br-<id> from <subnet> to any port <ssh-port> proto tcp comment 'coolify -> host ssh'`. Then ask the user to press "Validate Server" on the localhost server in Coolify. For a panel on another server, allow that server's IP instead. Coolify's troubleshooting puts most of its "server not reachable" reports on exactly this: a firewall or a `LIMIT` rule on 22.
3. **The panel owns 80 and 443.** Don't install Caddy or nginx on the host and skip the `web` profile's proxy steps: the panel's Traefik, Caddy or nginx terminates TLS. Check headers and TLS from outside as usual (`external-check.sh --domain`).
4. **Leave Docker's config to the panel.** Skip docker.md's localhost binding, `userland-proxy`, `default-address-pools` and `live-restore` changes: the panel's proxy must publish on `0.0.0.0`, and a changed address pool moves the bridge the panel's SSH comes from. Log rotation can stay if `daemon.json` has none. Don't re-pin or un-hold Docker (Dokploy holds its version with `apt-mark hold`; leave Docker out of unattended-upgrades there).
5. **Docker-published ports bypass ufw.** The panels publish their dashboards on the public interface: Coolify 8000 (plus 6001 and 6002), Dokploy 3000, CapRover 3000. Close them only after the user has opened the dashboard through its domain over HTTPS, the way each panel documents it (below), or in the provider firewall. Closing them first locks the user out of the panel. Until then `audit.sh` reports the dashboard port as a FAIL (`exposure.docker`); record it in SERVER.md and the final report as the one open step. If the user has DOCKER-USER rules (ufw-docker, firewall.md), allow the proxy's 80/tcp, 443/tcp and 443/udp there, and the dashboard port until it's closed. Docker Swarm ports (2377/tcp, 7946/tcp+udp, 4789/udp) are opened by Dokploy and CapRover even on one node: ufw's default deny already covers them, so don't open them; on a cluster, allow them only from the other nodes.
6. **Back up what the panel can't restore without.** Add the panel's data to `/etc/restic/include` and dump its database in a pre-hook (backups.md). The panel's own backup feature, if the user uses it, doesn't cover app volumes.

## Per tool

| | Coolify v4 | Dokploy | CapRover | Kamal 2 | Dokku |
|---|---|---|---|---|---|
| SSH | root to its own host and to managed servers; key in `/root/.ssh/authorized_keys`, private key in `/data/coolify/ssh/keys/` | none on its own host; root to remote servers (non-root unsupported) | root to worker nodes only | root by default, from the laptop or CI | `dokku@host` for git push; root not needed, but `dokku` must be in `sshusers` |
| Proxy | `coolify-proxy` (Traefik, or Caddy) | Traefik | nginx (`captain-nginx`) | kamal-proxy | nginx on the host (ufw applies normally) |
| Dashboard port | 8000, 6001, 6002 | 3000 | 3000 | none | none |
| Close it after the domain works | `/data/coolify/source/docker-compose.custom.yml` with `ports: !override []` for the dashboard services (survives updates) | `docker service update --publish-rm "published=3000,target=3000,mode=host" dokploy` | provider firewall | n/a | n/a |
| Data to back up | `/data/coolify`, above all `/data/coolify/source/.env` (its `APP_KEY` decrypts every stored credential) | `/etc/dokploy`, volumes `dokploy` and `dokploy-postgres` | `/captain/data` | the accessories' `directories:` | `/home/dokku`, `/var/lib/dokku/{config,data,services}` |
| Swarm | no (deprecated) | yes, always | yes, always | no | no |

Kamal specifics:
- Kamal's accessories publish ports exactly as written. A bare `port: 3306` or `5432:5432` is open to the internet past ufw. Check `docker ps` for `0.0.0.0:` database ports and have the user change them to `127.0.0.1:3306:3306` in `config/deploy.yml`.
- To get off root, set `ssh: user: <admin>` in `config/deploy.yml` and add that user to the `docker` group. Tell the user that membership in `docker` is equivalent to root on that host. Keep root's key until a `kamal deploy` as the new user has worked once.

Dokploy runs its own security check on remote servers (ufw active with default deny, key-only SSH, fail2ban). A hardened server passes it except for its "UsePAM off" recommendation. Keep `UsePAM yes`: the SSH-login alert hooks into PAM.

## "Harden first, then install Coolify"

The best order for a fresh box, and the one to suggest. Run the normal workflow with the panel in mind: root key login kept and root in `sshusers` (item 1), no host proxy, no Docker daemon changes, ports 22, 80 and 443. Then let the user run the panel's installer. Afterwards, come back for three steps: the Docker pools into `ignoreip` and the ufw allow rule (item 2, the pools exist only now), the panel's data into backups (item 6), and, once the dashboard works on its domain, closing the dashboard port (item 5). Run `audit.sh` at the end and explain the expected root-login WARN in SERVER.md.

## What not to do

- Don't set `PermitRootLogin no` on a server a panel or Kamal manages as root, even with the user's offline approval of the standard steps. Offer the non-root route the tool supports instead (Kamal), or keep root key-only and say why.
- Don't put a host Caddy in front of the panel's proxy, and don't move the panel's proxy off 80/443.
- Don't "clean up" containers, networks, keys or cron jobs you don't recognise on a panel host. They are usually the panel's.
