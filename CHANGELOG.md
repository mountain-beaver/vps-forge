# Changelog

## 1.0.1 (2026-10-24)

Text and documentation only. The scripts behave exactly as in 1.0.0.

### Skill
- **The skill's `description` now says when not to use it:** RHEL/Fedora-family servers, Kubernetes nodes, Proxmox and other hypervisor hosts, managed hosting without root, and the user's own desktop. On Kubernetes nodes and hypervisor hosts, `ufw default deny routed` and strict `rp_filter` would break pod and VM networking.
- **Safety rule 1 is now two rules:** "never cut off access" (the dead-man switch, testing over a new connection, disarming, what the switch covers) and "never ban yourself" (the admin's IP on every exemption list before anything can count it). The content stays in `SKILL.md`, because the agent must not miss it.
- **`references/ssh.md` no longer says a file created after `arm` can survive a rollback.** The rollback deletes such files, and the tests check it. The temporary sudo grant survives only if it was created outside an armed window.
- **The dead-man switch no longer claims to cover "VPN routing".** It snapshots sshd, firewall, sudoers and PAM files, not WireGuard, Tailscale or netplan config. `references/vpn.md` now says so and warns against routing the server's own traffic into a tunnel.
- **`references/ssh.md` notes that deadman snapshots hold root-only copies of the host keys.** If you rotate the keys, delete the old snapshots too.

### README
- **Costs:** a run with the skill cost a median $1.87 at API list prices, against $0.62 without it.
- **New caveats:**
  - the charts show a checklist score, not a general security index;
  - about 70% of the gap comes from three checks that match the skill's own defaults (`ssh-audit`, root login, login alerts), and `results.md` now has the scores without them;
  - the skill targets `ssh-audit`, and the judge checks `ssh-audit`;
  - there are three runs per cell, and the judge was written by the skill's author;
  - every prompt said the user was offline, so the intake questions and approvals were never tested.
- **The no-agent `audit.sh` download is pinned to a release tag,** and the check count reads 70+ (there are 76).
- **The lockout section is reworded.** No lockout is a design guarantee: the benchmark saw 0 lockouts in both arms. What it measured is the difference in self-bans.
- **The replay moved above the install instructions**, and the examples table is shorter.

### How the skill was developed
- The public history starts at 1.0.0, but the skill was revised before that.
  - An earlier build scored 92, 100 and 89 on the first three benchmark scenarios.
  - In 12 of its 45 runs, the agent's own test logins tripped the fail2ban it had just installed.
- The revisions that followed are listed under 1.0.0:
  - fail2ban stays masked until the admin's IP is on its ignore list;
  - root moves to an admin user;
  - the hardened baseline applies to short checklists too.
- [bench/README.md](https://github.com/mountain-beaver/vps-forge/blob/main/bench/README.md) has both benchmark runs.

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
