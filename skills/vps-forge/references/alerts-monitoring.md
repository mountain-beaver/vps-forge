# Alerts and monitoring

A good server tells its owner when something is wrong, before the owner has to notice. Aim for **few, actionable alerts on the user's phone** and a heartbeat that catches the server itself dying.

## Contents
- Channels
- install-alerts.sh
- Heartbeat and backup monitoring
- External uptime checks
- Metrics dashboards
- Logs

## Channels

| Channel | Setup | Notes |
|---|---|---|
| **ntfy** | Install the ntfy app and subscribe to a topic | Public ntfy.sh topics are readable by anyone who knows the name. Use a long random topic (`openssl rand -hex 16`), an access token, or self-hosted ntfy. |
| **Telegram** | @BotFather → `/newbot` → token. The user messages the bot, then reads `chat.id` from `https://api.telegram.org/bot<token>/getUpdates` | The token is a secret. It goes only into `/etc/vps-forge/notify.env`. |
| **Webhook** | Slack incoming webhook, Discord webhook, or any JSON endpoint | `WEBHOOK_FORMAT=slack\|discord\|json` |

## install-alerts.sh

First write `/etc/vps-forge/notify.env` (mode 600) with the channel settings. See `assets/alerts/notify.env.example`. Write it over SSH via heredoc so secrets don't appear in command lines, and create it private from the start: `sudo sh -c 'umask 077; cat > /etc/vps-forge/notify.env'` (the installer also creates a missing file with `install -m 600`). Then:
```bash
ssh host 'sudo bash -s -- --ssh-login --health' < scripts/install-alerts.sh
ssh host 'vps-notify "Test" "Alerts from $(hostname) work" high'
```
**Ask the user to confirm the test message arrived.** That's part of the definition of done.

What gets installed:
- `/usr/local/bin/vps-notify TITLE MESSAGE [low|default|high]` sends to every configured channel. Secrets are passed to curl through stdin config, never argv, so other local users can't see them in `ps`.
- `--ssh-login`: a `pam_exec` hook (optional, non-blocking, backgrounded) that sends "SSH login: user@host from IP". It fires per connection, which is why this phase comes near the end. The first login from a `user@address` not seen for `SSH_ALERT_KNOWN_DAYS` (30) is high priority; later ones from it are low priority (no sound) and at most one an hour, so the owner's own scp, rsync and CI deploys don't train them to mute the channel. `SSH_ALERT_IGNORE_IPS` silences an address completely: use it for a CI runner with a fixed IP, never for the admin's own address, whose login alert is the point.
- `--health`: `vps-forge-health.timer` runs every 5 minutes and alerts on failed systemd units, a filesystem ≥ `DISK_WARN_PCT` (85), inodes ≥ 90%, `reboot-required`, kernel OOM kills (each kill line once), and an overdue backup: no successful `vps-forge-backup` run for `BACKUP_MAX_AGE_HOURS` (36), read from `/var/lib/vps-forge/backup/last-success`, which the backup script writes. Alerts are de-duplicated: the same problem re-alerts at most every 6 hours, and you get a "resolved" message when it clears. After a fix, failed units and an overdue backup alert again 15 minutes later if they fail again; disk and inodes keep the 6 hour wait. The check runs under `TimeoutStartSec=2min` and `timeout 20 df`, so a hung mount can't wedge the timer. If `HC_HEARTBEAT_URL` is set, it pings it on every run, so a dead or frozen server alerts via healthchecks.io.

Uninstall: `install-alerts.sh --uninstall` removes the hook, timer and binaries, and keeps `notify.env`.

## Heartbeat and backup monitoring

- healthchecks.io (free tier) or self-hosted Healthchecks:
  - "server heartbeat": period 5 min, grace 10 min → `HC_HEARTBEAT_URL`
  - "backup": period 1 day, grace 6 h → `HC_URL` in `/etc/restic/env`
- Healthchecks itself can notify ntfy, Telegram, email and others.

## External uptime checks

Something **outside** the server has to watch it:
- UptimeRobot, Better Stack, or Uptime Kuma on another machine. Use HTTPS keyword checks for the site, a TCP check for the SSH port (or VPN), and certificate-expiry alerts (Caddy and certbot renew automatically, but an alert catches broken renewals).
- Don't host the monitor of a server on the same server.

## Metrics dashboards (optional)

- **Beszel**: very light hub + agent, Docker-friendly, with alerts. Good for 1–10 servers.
- **Netdata**: rich per-second metrics. Heavier; disable cloud features if the user doesn't want them.
- **node_exporter + Prometheus + Grafana**: the standard choice when the user already runs this stack.

Whatever is chosen: bind the UI to `127.0.0.1` or the VPN interface. A metrics UI exposed to the internet is an information leak and frequently an RCE.

## Logs

- `journalctl -p warning -b --no-pager | tail -n 50` shows what went wrong since boot.
- `journalctl -u ssh --since today | grep -E 'Accepted|Failed'` shows who got in.
- For a daily email digest, `logwatch` works but needs an MTA. Most users are better served by the alerts above.
