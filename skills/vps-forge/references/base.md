# Base system

## Contents
- Safety net (do this first)
- Non-interactive apt
- Packages
- Automatic security updates
- needrestart
- Time, timezone, hostname
- Swap / zram
- journald
- Ubuntu Pro and Livepatch
- etckeeper
- Reboot drill (phase 11)

## Safety net (do this first)

1. **Provider snapshot.** Ask the user to take one now if the provider supports it (Hetzner, DigitalOcean, Vultr and Linode all do). It's the cheapest undo button there is.
2. **Console access.** Confirm the user can open the provider's web console (VNC/serial). On Hetzner it's Cloud Console → server → `>_`; on DigitalOcean it's Droplet → Access → Recovery Console. The console needs a password for an account. If root has no password and you are about to disable password SSH, decide with the user whether to set a strong root password for console-only use. A password-based PermitRootLogin over the network stays off either way; the console doesn't go through sshd.
3. **etckeeper** (section below) before the first config change.
4. **deadman:** install the helper once, then use it around every risky change:
   ```bash
   ssh host 'sudo install -m 755 /dev/stdin /usr/local/sbin/vps-forge-deadman' < scripts/deadman.sh
   ```

## Non-interactive apt

Phase 2 runs in this order:
1. **1 GB RAM or less, and no swap:** create the swapfile first (see "Swap / zram"). On 512 MB, dpkg, etckeeper and needrestart can run out of memory mid-upgrade and leave half-configured packages.
2. **fail2ban is masked and its jail is written** before anything installs it (see "Packages").
3. Upgrade, then one `apt-get install`.

Everything you run over SSH must be non-interactive, otherwise apt waits forever on a config-file question or the needrestart dialog.

```bash
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
apt-get update && $APT full-upgrade && $APT autoremove --purge
```
`--force-confold` keeps the existing config when a package ships a new one. Mention it if a `*.dpkg-dist` file appears, because it may contain new defaults worth merging.

**Existing production server (audit mode)?** Use `$APT upgrade`, not `full-upgrade`, and skip `autoremove --purge`, which can remove packages that were only marked as automatic. First list what would change and restart: `apt-get -s upgrade | grep '^Inst'`. Call out `docker.io`/`docker-ce`/`containerd`: an upgrade restarts the daemon, and with it every container unless `live-restore` is on. Get the user's OK before running it.

If the upgrade installed a new kernel (`/var/run/reboot-required` exists), plan a reboot **now**, with the user's OK, before the risky SSH and firewall steps. That way any reboot problem isn't confused with your changes.

## Packages

fail2ban starts the moment it is installed on Debian 13 and Ubuntu 24.04, with the stock sshd jail and without the admin's IP. On start it re-reads recent journal lines, so your earlier test logins ban the user at once. Mask it first and write its jail (`sudo` before each command when not root):
```bash
ADMIN_IP=$(vps-forge-deadman client-ip) && [[ $ADMIN_IP =~ ^[0-9A-Fa-f:.]+$ ]] || { echo "no admin IP: stop"; exit 1; }
systemctl is-active --quiet fail2ban || systemctl mask fail2ban
install -d -m 755 /etc/fail2ban/jail.d
# write assets/fail2ban/vps-forge.local to /etc/fail2ban/jail.d/ with <admin-ip> = $ADMIN_IP
# and <ssh-port> = the port sshd listens on now
```
Phase 5 unmasks and starts it (firewall.md "Start order"). If fail2ban is already running, don't mask it: write the jail, then `fail2ban-client -t && systemctl restart fail2ban`.

Baseline set (Debian and Ubuntu):
```bash
$APT install ca-certificates curl wget gnupg git vim less htop btop ncdu tmux jq unzip rsync \
  ufw nftables fail2ban python3-systemd unattended-upgrades apt-listchanges needrestart \
  etckeeper sudo bash-completion dnsutils
```
- **Install everything in one go.** Add the packages the chosen profiles need to this same command: `restic` for backups, Docker or Caddy from their own repositories after adding them, `libpam-google-authenticator` for paranoid. Every separate `apt-get install` costs 20–40 s, because etckeeper and needrestart run each time.
- `python3-systemd` is required for fail2ban's systemd backend on Debian 12+. Without it fail2ban won't start.
- Install `nftables` even when you manage rules with ufw: you need `nft` for inspection, and fail2ban bans through it.

Don't install a pile of tools "just in case". Every package adds attack surface and update noise.

## Automatic security updates

Write the files directly rather than running `dpkg-reconfigure`, which prompts:

`/etc/apt/apt.conf.d/20auto-upgrades` (from `assets/apt/20auto-upgrades`):
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```
`/etc/apt/apt.conf.d/52vps-forge-unattended` (from `assets/apt/52vps-forge-unattended`): removes unused kernels and dependencies and logs to syslog. Auto-reboot is **off** unless the user agrees. For `paranoid`, or for anyone who wants it, enable it at a quiet time such as `Automatic-Reboot "true"` and `Automatic-Reboot-Time "04:30"`, and tell the user the box will reboot itself when a kernel update needs it.

The default origins already cover security updates (Ubuntu `-security`, Debian `Debian-Security`). Add `-updates` only if the user wants all stable updates applied automatically.

Third-party repositories are not covered: Docker and Caddy then never update by themselves. Tell the user, and if they agree, add their origins to `52vps-forge-unattended`:
```
Unattended-Upgrade::Origins-Pattern {
  "origin=Docker,label=Docker CE";
  "origin=cloudsmith/caddy/stable";
};
```
Check the exact `origin`/`label` values with `apt-cache policy | grep -A1 -E 'docker|caddy'` (the `o=` and `l=` fields). Unattended Docker upgrades restart the daemon, and with it every container that has no restart policy.

Verify:
```bash
apt-config dump APT::Periodic::Unattended-Upgrade   # "1"
unattended-upgrade --dry-run --debug 2>&1 | tail -n 15
systemctl list-timers apt-daily-upgrade.timer
```

## needrestart

`assets/needrestart/50-vps-forge.conf` sets `$nrconf{restart} = 'a';`, so services that use updated libraries are restarted automatically instead of prompting. needrestart deliberately skips `ssh`'s active sessions and the systemd manager itself. Kernel updates still need a reboot, and the health timer from `install-alerts.sh` reports `reboot-required`.

## Time, timezone, hostname

- **Time sync:** `timedatectl show -p NTPSynchronized --value` should print `yes`. `systemd-timesyncd` is enough. Install `chrony` only if the box is a time-sensitive service (Kerberos, trading, databases with strict clocks).
- **Timezone:** recommend **UTC** for servers, because logs line up across machines and nothing jumps at DST. Use the local zone only if the user asks: `timedatectl set-timezone America/New_York`.
- **Hostname:** `hostnamectl set-hostname <name>` and make sure `/etc/hosts` has `127.0.1.1 <name>`. On cloud images, **cloud-init may reset the hostname at boot**. Add `/etc/cloud/cloud.cfg.d/99-vps-forge.cfg` containing `preserve_hostname: true`, and set `manage_etc_hosts: false` if you edit `/etc/hosts` yourself.

## Swap / zram

- Container VPS types (OpenVZ/LXC, check with `systemd-detect-virt`) usually can't add swap. Skip this there.
- If RAM is 2 GB or less and there is no swap, add a swapfile of 1–2 GB. At 1 GB or less, do it before the upgrade and the big install:
  ```bash
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ```
  On btrfs, use `btrfs filesystem mkswapfile --size 2G /swapfile` instead of fallocate. That needs btrfs-progs 6.1+ (Debian 12+, Ubuntu 24.04+). On Ubuntu 22.04: `truncate -s 0 /swapfile && chattr +C /swapfile && fallocate -l 2G /swapfile`, then `chmod`/`mkswap`/`swapon` as above.
- `vm.swappiness=10` goes in the sysctl file (see kernel.md).
- An alternative for very small boxes: zram (`systemd-zram-generator` on Debian 12+ / Ubuntu 24.04, or `zram-tools`), which compresses memory instead of writing to disk. Don't use zram and a swapfile at the same priority.

## journald

`assets/journald/10-vps-forge.conf` → `/etc/systemd/journald.conf.d/` (`SystemMaxUse=500M`, `MaxRetentionSec=1month`, `Compress=yes`). Then run `systemctl restart systemd-journald`. Make sure the journal is persistent: `/var/log/journal` must exist. Recent Debian and Ubuntu create it, but some minimal and provider images don't. If it's missing, run `mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal && systemctl restart systemd-journald`. Without a persistent journal, logs vanish at reboot, which is exactly when you need them. Debian 12+ no longer ships rsyslog, so there is no `/var/log/auth.log`. That is expected, and it's why fail2ban needs the systemd backend.

## Ubuntu Pro and Livepatch (Ubuntu only, hardened+)

Ubuntu Pro is free for up to 5 machines for personal use. The user gets a token at ubuntu.com/pro. It adds ESM security updates for universe packages and **Livepatch**, which applies kernel security fixes without a reboot. Livepatch supports most KVM-based VPS kernels, but not containers.
```bash
pro attach <token>        # the user should run this themselves or give the token directly; never echo it back
pro enable livepatch
pro status
```
Offer it; don't push it.

## etckeeper

```bash
$APT install etckeeper    # auto-initialises git in /etc and commits around every apt run
git -C /etc config user.name "vps-forge"; git -C /etc config user.email "root@$(hostname)"
# Keep later secrets out of the history. Append after etckeeper's managed block, before the files exist.
for l in 'restic/' 'vps-forge/*.env' 'wireguard/'; do grep -qxF "$l" /etc/.gitignore || printf '%s\n' "$l" >> /etc/.gitignore; done
etckeeper commit "vps-forge: baseline before changes" || true
```
On an existing server, check whether such files are already tracked (`git -C /etc ls-files restic vps-forge wireguard`). If so, `git -C /etc rm -r --cached <path>` and commit; the old commits still hold them, so tell the user.

Commit after each phase: `etckeeper commit "vps-forge: <phase>"`. To see a change, run `git -C /etc log --stat` and `git -C /etc show --stat <rev>`. Look at a single file's diff only when it holds no secrets. To revert one file, run `git -C /etc checkout <rev> -- ssh/sshd_config.d/00-vps-forge.conf`.

Never add a remote to `/etc/.git` or push it anywhere: it contains `shadow`, host keys and secrets. Its permissions are 700 for that reason.

## Reboot drill (phase 11)

With the user's OK, and with the provider console at hand, prove that SSH, the firewall and the app survive a reboot:
1. `vps-forge-deadman status` must say `not armed`. Don't arm for the drill: a reboot while armed rolls back at boot by design, and that restore re-applies the SSH and firewall state, which would hide exactly what the drill looks for. `disarm` would then report `ROLLED BACK`.
2. `systemctl reboot`. The multiplexed master dies with it.
3. After a minute, from a new connection: `ssh -o ControlPath=none -o BatchMode=yes -p <port> <admin>@<host> 'sudo -n ufw status | head -n 1; systemctl --failed --no-legend'`. Under password sudo without the temporary grant, expect `a password is required` and have the user run the checks. Then check the app (`docker ps`, `curl -sI https://<domain>`).

Under password sudo without the temporary grant, the reboot also ends the root session that the remaining root work depends on: run the drill after phase 12, or leave it to the user. If SSH doesn't come back, use the console: `systemctl status ssh ssh.socket ufw`, `journalctl -b -u ssh`.
