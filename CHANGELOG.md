# Changelog

## 1.0.0 (2026-10-24)

First public release.

### What's in it
- **A phased workflow:** recon → safety net → base → SSH → firewall → fail2ban → kernel → workload → backups → alerts → comfort → verify → document.
  - Three levels: baseline, hardened and paranoid.
  - Combinable profiles: web, docker, vpn, db, worker and game.
  - A short security checklist still gets the non-disruptive hardened baseline. The skill announces it up front.
- **`deadman.sh`: a snapshot and an automatic rollback** for SSH, ufw/nftables, sudoers and PAM changes.
  - The rollback is driven by a systemd timer, and also runs at boot if the server reboots while armed.
  - It removes files created after `arm`, restores unit enable states, unbans the admin in fail2ban and reports a partial rollback loudly.
  - It uses a lock, and `client-ip` works under sudo.
- **`audit.sh`: a read-only audit** with 40+ checks, a score, JSON output and compromise indicators.
  - It evaluates sshd `Match` blocks, Docker port mappings, IPv4 and IPv6 firewalls separately, boot-time enablement of sshd and the firewall, and download-and-execute cron jobs or units.
  - Untrusted text from the server is sanitized before it is printed.
- **`external-check.sh`: outside-in verification** of ports, SSH auth methods, root login, `ssh-audit`, TLS and headers.
  - Its probes fail closed.
  - It runs under the bash 3.2 that ships with macOS.
- **`install-alerts.sh`: `vps-notify`** sends to ntfy, Telegram or a webhook.
  - Alerts for SSH logins, failed units, full disks, OOM kills, overdue backups and pending reboots.
  - De-duplication, resolve messages and a heartbeat.
- **Validated templates:**
  - sshd (`00-` drop-in) with version-aware crypto, and sysctl;
  - fail2ban (systemd backend, `mode = normal`, SSH-only recidive);
  - unattended-upgrades, needrestart and journald;
  - Docker `daemon.json` and a Caddyfile;
  - restic units, a Cloudflare ufw sync (`CF_MODE=route` for containerised proxies) and cloud-init;
  - motd, a shell prompt and `SERVER.md`.

### Safety rules the skill follows
- **It never locks you out.** Every SSH, firewall, sudo or PAM change goes arm → change → validate → test from a fresh, non-multiplexed session → disarm.
- **The admin's IP goes into fail2ban's `ignoreip` before fail2ban first starts.** On a fresh box fail2ban stays masked until then, because Debian 13 and Ubuntu 24.04 start it on install.
- **Root login over SSH moves to an admin user that holds only your own key.**
  - Under password sudo, the generated password is written to `~/SUDO-PASSWORD` and is never printed or read by the agent.
  - Root stays locked only after that password has been proven to work.
- **The admin rule always goes ahead of `ufw limit`.** The admin address is also exempt from sshd `PerSourcePenalties`.

### Before release
- The scripts and instructions went through several review passes, and every verified finding was fixed.
- The skill was benchmarked on 120 real VM runs across Debian 12/13 and Ubuntu 22.04/24.04/26.04, with and without the skill, scored from outside the server by a separate judge. Details are in the [README](https://github.com/mountain-beaver/vps-forge#benchmark) and in [`bench/`](https://github.com/mountain-beaver/vps-forge/blob/main/bench/README.md).

### Tests and tooling
- `make test`: ShellCheck, manifest and eval schema checks, version agreement, and the `audit.sh` and `deadman.sh` round trips without root. It also runs `alerts`, `backup` and `cloudflare-sync` against stubs.
- `make ci`, in podman or docker on Debian 12/13 and Ubuntu 22.04/24.04:
  - every config template is checked by the tool that consumes it (`sshd -t/-T`, `fail2ban-client -t`, `caddy validate`, `cloud-init schema`, `apt-config`, `systemd-analyze verify`, `dockerd --validate`);
  - `audit.sh` runs against known good and bad states, with a filesystem checksum proving it is read-only;
  - the dead-man rollback runs on a real systemd.
- GitHub Actions run the same suites, plus a macOS job for bash 3.2. Releases check that the tag matches `plugin.json`.
- Behaviour evals live in `skills/vps-forge/evals/`, in `claude plugin eval` format.
