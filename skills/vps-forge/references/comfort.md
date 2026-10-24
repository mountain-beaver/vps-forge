# Comfort: make the server pleasant to live on

These details are what make a server feel cared for, rather than just secured.

## Status at login (motd)

`assets/motd/60-vps-forge` → `/etc/update-motd.d/60-vps-forge` (755). It runs on Debian and Ubuntu through `pam_motd`. On login it shows the hostname, OS, uptime and load, memory and disk, pending updates or reboot-required, failed units, fail2ban bans today, the last backup age (if the restic env exists), and the Docker container count.

Quiet the noise on Ubuntu (ask first, since some users like the news):
```bash
chmod -x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news 2>/dev/null
sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null
```
Test with `run-parts /etc/update-motd.d/ | head -n 40`. The script must stay fast (under 0.5 s); it never calls the network.

## Shell for the admin user

`assets/shell/vps-forge.bashrc` → `/etc/profile.d/vps-forge.sh`. Debian and Ubuntu's default `~/.bashrc` sets its own `PS1` after profile.d runs, so also append `[ -r /etc/profile.d/vps-forge.sh ] && . /etc/profile.d/vps-forge.sh` to the end of the admin user's `~/.bashrc`. It provides:
- A prompt that shows the host in **red for `prod`** hostnames (`*prod*`) and green otherwise, so you always know which box you're on.
- Large, timestamped, shared history (`HISTSIZE=50000`, `HISTTIMEFORMAT`, `histappend`).
- Safe aliases: `ll`, `ports` (`ss -tulpn`), `logs` (`journalctl -e`), `fw` (`sudo ufw status numbered`), `dps` (`docker ps --format` table).

Don't replace the user's dotfiles or switch them to zsh unless asked.

## Tools that earn their place

`htop`/`btop` (processes), `ncdu` (what's eating the disk), `tmux` (sessions that survive a dropped connection; recommend it for long upgrades), `jq`, and `dnsutils` (`dig`). They're installed in base.md. Don't add more without a reason.

## Small touches

- `needrestart -r l`: lists services that still run old libraries after updates.
- Set the admin user's `~/.ssh/authorized_keys` key comments to real device names (`you@laptop-2026`), so the audit output is readable.
- Add a one-line `~/.ssh/config` entry on the user's machine (ssh.md) so that `ssh myserver` just works.
