# Docker profile

If Coolify, Dokploy, CapRover, Kamal or Dokku manages Docker on this host, read paas.md first: most of the daemon changes below must be skipped there.

## Contents
- Existing Docker (check first)
- Install (official repo, not docker.io)
- daemon.json
- Who may run docker
- Compose layout and service hygiene
- Updates without surprises
- Housekeeping
- Rootless Docker (paranoid)

## Existing Docker (check first)

Before installing or reconfiguring anything: `command -v docker && docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'; docker info --format '{{.LiveRestoreEnabled}} {{.LoggingDriver}}'`.

If Docker is already running containers, this is a production box. Do **not** replace the engine (`docker.io` → `docker-ce`), edit `daemon.json` or turn on `live-restore` without the user's explicit OK, and list what will restart before asking:
- Replacing the engine package or restarting `docker.service` stops every container, unless live-restore is already on (check `docker info`). Containers without a restart policy stay down.
- `daemon.json` changes need a restart (or `systemctl reload docker` for `live-restore` itself, which avoids one). `log-driver`, `no-new-privileges` and `default-address-pools` only reach containers and networks created afterwards, so existing containers keep their old logging until they are recreated (`docker compose up -d --force-recreate`).
- A new address pool can collide with existing networks. Compare with `docker network ls` and `ip route` first.

If the user says no, keep the engine and skip the rest of this file except hygiene that needs no restart (compose layout, housekeeping). Note the skipped items in SERVER.md.

## Install

Use Docker's own apt repository. The distro's `docker.io` lags behind and ships without the compose plugin. If you have web access, check the current steps at https://docs.docker.com/engine/install/ (debian or ubuntu). The canonical form is:
```bash
. /etc/os-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update && $APT install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```
Remove the conflicting packages first if present: `docker.io docker-compose podman-docker containerd runc`.

## daemon.json

`assets/docker/daemon.json` → `/etc/docker/daemon.json`, validated with `python3 -m json.tool`, then `systemctl restart docker`:
```json
{
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "no-new-privileges": true,
  "default-address-pools": [{ "base": "172.30.0.0/16", "size": 24 }]
}
```
- `local` log driver with rotation: container logs can no longer fill the disk, and this is the most common cause of a full VPS.
- `live-restore`: containers keep running while dockerd restarts during upgrades. It's incompatible with Swarm mode; drop it there.
- `no-new-privileges`: setuid binaries inside containers can't escalate. Rarely, an image needs it off; override per service with `security_opt: ["no-new-privileges:false"]`.
- `default-address-pools`: avoids Docker grabbing ranges that collide with the user's VPN or office LAN. Pick a range that's free in their environment.

Restarting dockerd after changing `live-restore` restarts the containers once. Warn the user on a box already in production, or reload instead (`systemctl reload docker`). Live-restore also covers only patch releases of the engine; a major engine upgrade (`YY.MM`) can still stop containers.

Hardened option, not the default: make published ports bind to localhost unless a service says otherwise. The daemon key `"ip": "127.0.0.1"` covers **only the default bridge** (plain `docker run -p`). Compose projects use user-defined networks, which need `"default-network-opts": {"bridge": {"com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}}` as well (or the same option per network, or an explicit `127.0.0.1:` in each `ports:` entry as in the compose example below). Swarm services ignore both. Either way, a service that must be public (the reverse proxy) then needs an explicit address, `ports: ["0.0.0.0:80:80", "0.0.0.0:443:443"]`, or it silently becomes unreachable. Restart dockerd for the change (see "Existing Docker"), and verify with `ss -tlnp` after `docker compose up -d`. This narrows the Docker-bypasses-ufw problem (firewall.md) but doesn't replace the DOCKER-USER rules for ports that are public on purpose.

## Who may run docker

Membership in the `docker` group is **root-equivalent**: anyone in it can mount `/` into a container. Say this plainly before adding the admin user to the group. Alternatives: use `sudo docker`, or rootless Docker (below).

## Compose layout and service hygiene

One directory per app, everything in it, which also makes it easy to back up:
```
/opt/<app>/
  compose.yaml
  .env            # mode 600, secrets only here
  data/           # bind-mounted state (prefer this over anonymous volumes)
```
Per-service defaults to suggest, and to apply where the image allows:
```yaml
services:
  app:
    image: ghcr.io/org/app:1.4.2        # pinned tag (or @sha256 digest), never :latest in prod
    restart: unless-stopped
    ports: ["127.0.0.1:8080:8080"]      # localhost only; the reverse proxy exposes it
    env_file: .env
    read_only: true                     # plus tmpfs: [/tmp] if the app writes temp files
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    user: "1000:1000"                   # if the image supports a non-root user
    mem_limit: 512m
    pids_limit: 256
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 30s
      retries: 3
```
Databases and caches get **no `ports:`** at all. Other services reach them over the compose network by service name.

## Updates without surprises

- Prefer notification-based updates: [Diun](https://crazymax.dev/diun/) watches the registries and sends a notification (it supports ntfy and Telegram natively), and the user updates with `docker compose pull && docker compose up -d`. Blind auto-updaters are how a breaking major version lands at 3 a.m.
- Docker Engine itself updates through apt. unattended-upgrades only covers the Docker repo if its origin is added, so mention this and let the user decide.

## Housekeeping

A weekly timer removes old unused images and build cache. `until=168h` filters on **creation time**, not on when an image was last used: an image built or published more than a week ago goes if no container, running or stopped, references it. Containers, volumes and networks are not touched. Don't use `docker system prune -af --filter until=...` here: it also deletes stopped containers by creation time, together with their writable layers.
```ini
# /etc/systemd/system/docker-prune.service
[Unit]
Description=Prune old unused Docker images and build cache
[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -af --filter "until=168h"
ExecStart=/usr/bin/docker builder prune -af --filter "until=168h"
```
```ini
# /etc/systemd/system/docker-prune.timer
[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
```
Then `systemctl daemon-reload && systemctl enable --now docker-prune.timer`. Unused volumes are never pruned automatically: `docker volume prune` can delete data from a stopped database, so run it by hand and read the list.

## Rootless Docker (paranoid)

With rootless Docker, the daemon runs as an unprivileged user, so a container escape lands as that user, not root. Costs: ports below 1024 need `net.ipv4.ip_unprivileged_port_start` or a proxy, some network drivers and cgroup limits are unavailable, and logging and systemd integration differ. Install with `dockerd-rootless-setuptool.sh install` as the target user, after `apt-get install uidmap dbus-user-session`. Usually worth it only for multi-tenant boxes or untrusted images. ufw rules do apply to rootless Docker: published ports are bound by a userspace proxy process (RootlessKit), not by iptables rules in the host's `nat` table, so the ufw-vs-Docker bypass in firewall.md does not occur and a plain `ufw allow` is what opens a port.
