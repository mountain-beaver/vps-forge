# Changelog

## Unreleased

### Distribution
- **Directory listing details in `plugin.json`:** `displayName` (so the listing reads vps-forge, not "Vps Forge"), the icon path, and links to the documentation, the issue tracker and a new `PRIVACY.md`.
- **`PRIVACY.md`:** the project collects nothing; it lists what the skill sends where, all of it to services you choose, including the certificate contact email that goes to Let's Encrypt.

### Safety
- **Provider firewalls are named as outside the dead-man switch.** The switch only snapshots files on the server, so a rule in the provider's panel or API can't roll back. The skill now changes those additively (add the new rule, prove a new login, remove the old rule last) and never replaces a whole rule set in one call. The README no longer says that every change that could cut you off rolls itself back.

### Dead-man switch
- **`vps-forge-deadman extend MINUTES`** moves a pending rollback to MINUTES from now and keeps the same snapshot, for a change that takes longer than the window. It refuses once the rollback has fired or while it runs, and if it can't schedule the new timer it rolls back at once instead of leaving the change unguarded. The skill arms 10 minutes for multi-step changes and never extends after a failed test login.

### Alerts
- **SSH login alerts no longer train you to mute them.** The first login from a `user@address` not seen for `SSH_ALERT_KNOWN_DAYS` (30) is still high priority. Later logins from it come at low priority, without sound, and at most one an hour, so your own scp, rsync and deploys stay quiet while a new address still rings. `SSH_ALERT_KNOWN_DAYS=0` alerts every login as before. Re-run `install-alerts.sh --ssh-login` to update the hook.

### Deploy panels
- **Coolify, Dokploy, CapRover, Kamal and Dokku** (`references/paas.md`). These tools manage the server as root, run their own proxy on 80/443 and their own Docker setup, and the hardened defaults used to break them quietly: the next deploy failed. The skill now looks for them in recon and asks about them in intake. When one is there, root keeps key login, the panel's own SSH from its Docker network is exempt from fail2ban and from the SSH rate limit, no second proxy and no Docker daemon changes go in, the dashboard port closes only once the dashboard works on its domain, and the panel's data (Coolify's `APP_KEY` above all) goes into the backups. It also suggests the best order for a new box: harden first, then install the panel.
- **Fix: root login kept for a deploy key really works now.** When the skill kept `PermitRootLogin prohibit-password` for a pipeline that logs in as root, `AllowGroups sshusers` still refused root, so the next deploy failed anyway. Root now joins `sshusers` whenever its key login is kept. The deploy-key check also looks for Coolify, Dokploy, CapRover and Kamal keys, and asks about Kamal, which logs in as root by default.
- New eval: a Coolify host.

### Script mode
- **A real procedure for chat apps without SSH** (`references/script-mode.md`). The agent asks for a read-only audit first and writes nothing blind. Then it hands over one short script per stage, as a bundle to copy with `scp`, and reads the pasted output before the next one. Before every SSH, firewall, sudo or PAM change the script stops and asks the user to log in from a second terminal, which is what disarms the switch; the script never disarms itself. The final report says what script mode couldn't check.

### Backups and updates
- **SQLite databases are dumped, not copied live.** PocketBase, n8n, Uptime Kuma and similar apps keep their data in SQLite, and a file copy taken mid-write can restore as corrupt. The skill finds these files during recon, dumps each one with `sqlite3 .backup`, keeps the live file out of restic, and checks the restore with `PRAGMA integrity_check`.
- **Vendor repositories get automatic updates too.** When the skill adds Caddy, Tailscale or CrowdSec, it adds their origin to unattended-upgrades in the same phase, and asks first for Docker, whose upgrade restarts every container. `audit.sh` has a new check, `updates.third_party`: it warns when Docker, Caddy, Tailscale or CrowdSec isn't followed by unattended-upgrades, and notes any other third-party repository, such as a provider's agent, without a warning.

### Tests
- **The dead-man rollback and the systemd-only audit checks run in CI**, in a podman container that boots systemd: a broken sshd and a drop-all firewall rolled back by the timer, the rollback at boot after a reboot while armed, and concurrent arms, and `extend`. Both suites build their image when it's missing, and in CI a missing podman is a failure instead of a skip.

### Docs
- **Quick start:** `npx skills add … -g` is the default, so the agent finds the skill in any folder; the Node.js version it needs; how to check the skill loaded; which key the agent uses, on the first screen.
- **FAQ:** how to update or remove the skill, and how to undo what it did on a server; Oracle Cloud, AWS EC2 and ARM are listed; the lockout answer starts with the provider firewall.
- **Benchmark:** the hero chart marks the SSH port move, whose 100 comes from behaviour 1.1.0 removed; the caption under it is one line; `bench/README.md` says how to reproduce the benchmarked pre-release skill from the `v1.0.0` tag.

## 1.1.1 (2026-10-25)

The skill and its scripts behave exactly as in 1.1.0. This release changes the README, its images and the packaging.

### Look
- **A new visual identity.** The mark is a pair of brackets around a square: every change is held open until a fresh login proves it, then committed or rolled back. The README banner, the replay, the charts and the social preview are redrawn in it, in light and dark versions, with IBM Plex Sans and Mono outlined so nothing depends on web fonts.
- **A dead-man switch diagram** above the step list: arm, change, verify from a new connection, disarm, and the path where the login is refused and the timer rolls everything back. It animates where the browser allows it and holds still under reduced motion. The recording of a real rollback stays below it, redrawn from the same recording in the new colours.
- **The benchmark charts show the whole picture.** The checks chart has every check that differs between the arms, one square per run, grouped into the skill's own defaults, the checks beyond them, and incidents. It says how many checks passed in every run. The per-distro grid lists each run under the mean.
- `bench/report.py` and `bench/spot.py` write their plain preview charts to `bench/out/charts/` instead of `docs/bench/`, so a new report can't overwrite the README charts. `results.md` and `results.json` stay where they were.

### Distribution
- **A `directory` branch for Anthropic's plugin directory.** It holds only the plugin: the manifest and icon, the skill without its evals, the license and a short README that says what the plugin runs and where data goes. A workflow rebuilds it on every release tag, so the benchmark harness and tests stay out of what people install from the directory. `make directory` builds the same folder locally.
- **Plugin icon** at `.claude-plugin/icon.png`.

### Docs
- **Before you start:** the Quick start now says to take a snapshot and find the provider's web console first, and to try a throwaway box the first time.
- **FAQ:** which key the agent logs in with, what happens to root and to its temporary sudo grant, and how to keep the result from getting in your way (levels, narrow requests).
- **Dead-man switch:** the README says where a rollback is logged and that it sends a "Deadman fired" alert once alerts are set up.
- **GLM-5.3 spot check.** Four runs of GLM-5.3 in the ZCode desktop app, with and without the skill: 79 → 100 and 67 → 100, no lockouts. Results in `docs/bench/glm-5.3.md`, caveats in the README.
- **Benchmark harness:** `BENCH_MANUAL` lets a person drive a desktop agent while the harness boots, relays and judges the VM.

## 1.1.0 (2026-10-24)

Behaviour changes. The benchmark in the README ran before them; see its caveats.

### Skill
- **Narrow requests get only what was asked.** "Move SSH and add fail2ban" no longer brings a firewall, new SSH crypto and a move off root with it. The skill does the request safely: the dead-man switch, and the admin's IP on fail2ban's ignore list before fail2ban starts. Then it offers the rest in one line, naming the gaps it found. The full hardened baseline still applies when the user asks for the whole server: set up, secure, harden or make production-ready. "I'm offline, decide yourself" no longer widens a narrow request.
- **The temporary passwordless sudo grant has a deadline.** A persistent systemd timer deletes `/etc/sudoers.d/90-vps-forge-temp` after 4 hours, even if the session drops or the server reboots. `audit.sh` shows the deadline, or says that a leftover grant has none.
- **The restore drill restores the app's data and the newest database dump** and compares them with the live files. Restoring `/etc/hostname` only proved that restic runs.
- **Recon stops on Kubernetes nodes** (k3s, kubeadm, rke2) **and hypervisor hosts** (Proxmox, libvirt, LXD/Incus). On RHEL-family systems it stops too, instead of following the same phases with different tools.
- **The Caddyfile template starts HSTS at `max-age=300`.** `references/web.md` describes raising it to a year once HTTPS works everywhere.
- **Tailscale and CrowdSec come from their signed apt repositories,** set up explicitly instead of through `curl | sh`.
- **`deadman.sh` is installed through stdin,** not through a file in a shared `/tmp`.
- **New behaviour evals:** a narrow request, a k3s node and a local `nginx.conf` question that must not trigger the skill.

### Tests and tooling
- CI and `make ci` cover Ubuntu 26.04.
- GitHub Actions are pinned to commit SHAs.
- `bench/demo.py` records the dead-man switch demo in a systemd container and renders it as an animated SVG, and as frames for video.

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
- `make ci`, in podman or docker on Debian 12/13 and Ubuntu 22.04/24.04/26.04:
  - every config template is checked by the tool that consumes it (`sshd -t/-T`, `fail2ban-client -t`, `caddy validate`, `cloud-init schema`, `apt-config`, `systemd-analyze verify`, `dockerd --validate`);
  - `audit.sh` runs against known good and bad states, with a filesystem checksum proving it is read-only;
  - the dead-man rollback runs on a real systemd.
- GitHub Actions run the same suites, plus a macOS job for bash 3.2. Releases check that the tag matches `plugin.json`.
- Behaviour evals live in `skills/vps-forge/evals/`, in `claude plugin eval` format.
