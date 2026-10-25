# Troubleshooting

## Locked out

0. **Banned by fail2ban?** If SSH times out or is refused right after test logins, your IP is probably banned (the deadman doesn't touch fail2ban). From another IP (phone hotspot) or the console: `fail2ban-client banned` (`fail2ban-client status sshd` on 0.11, Ubuntu 22.04), then `fail2ban-client set sshd unbanip <ip>` and `fail2ban-client set recidive unbanip <ip>`. Then put it into `ignoreip` in `/etc/fail2ban/jail.d/vps-forge.local` and `systemctl reload fail2ban`, so the next test logins don't ban it again (firewall.md).
1. **Wait for the deadman.** If it was armed, it restores the SSH, firewall, sudoers and PAM config, the ssh/firewall units' enabled state, and removes files created during the window when the timer fires (default 5 min). Then try again. Check later with `journalctl -t vps-forge-deadman`.
2. **Provider console** (VNC/serial): log in with a console password, or with root's password if one was set. Then:
   ```bash
   vps-forge-deadman restore          # if the snapshot exists
   # or by hand:
   ufw disable
   mv /etc/ssh/sshd_config.d/00-vps-forge.conf /root/   # also 01-vps-forge-crypto.conf
   sshd -t && systemctl restart ssh
   ```
3. **No console password:** use the provider's rescue system. Boot into rescue, mount the root disk, then either `chroot` and repair, or append the key to `/mnt/home/<admin>/.ssh/authorized_keys` and fix `/mnt/etc/ssh/sshd_config.d/`.

## `Permission denied (publickey)` after hardening

- Is the user in `sshusers`? Check with `id <admin>`. `AllowGroups` rejects everyone else, and the log says "not allowed because none of user's groups are listed".
- Permissions (`StrictModes`): the home directory must not be group- or world-writable, `.ssh` must be 700, and `authorized_keys` must be 600 and owned by the user.
- The client is offering the wrong key: `ssh -v` shows which keys it tries. Too many keys cause "Too many authentication failures" before the right one is offered. Fix with `IdentitiesOnly yes` and `IdentityFile` in `~/.ssh/config`.
- Server side: `journalctl -u ssh -n 50 --no-pager`.

## "Host key changed" or "keys of different type are already known"

This is expected after restricting `HostKey` to ed25519. Verify the fingerprint against `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` (read through the console or the existing session), then `ssh-keygen -R <host>` on the client.

## Password login still works

A file that sorts earlier in `sshd_config.d/` wins (cloud-init's `50-cloud-init.conf` vs a `99-` file), or a directive above the `Include` in `sshd_config` wins. Run `sshd -T | grep passwordauth` and `grep -rn PasswordAuthentication /etc/ssh/`. Name the file `00-vps-forge.conf`.

## Port change didn't take effect (Ubuntu 24.04)

SSH is socket-activated, so run `systemctl daemon-reload && systemctl restart ssh.socket`, then `ss -tlnp | grep ssh`.

## Hostname or /etc/hosts reverts after reboot

cloud-init. Set `preserve_hostname: true` (and `manage_etc_hosts: false`) in `/etc/cloud/cloud.cfg.d/99-vps-forge.cfg`.

## fail2ban won't start or catches nothing

- `systemctl is-enabled fail2ban` says `masked`: a run stopped between phases 2 and 5. Check that `jail.d/vps-forge.local` has the admin IP in `ignoreip`, then `systemctl unmask fail2ban && systemctl enable --now fail2ban`.
- `fail2ban-client -d` prints the parsed config and the error.
- `ImportError: systemd` → `apt-get install python3-systemd`.
- Python 3.12 `asynchat` error on Ubuntu 24.04 → upgrade fail2ban.
- The jail runs but `Total failed` never rises: the log source doesn't match. Test the filter with `fail2ban-regex systemd-journal sshd` (Debian 13: use Debian's fail2ban package, which is patched for `sshd-session`; stock upstream 1.1.0 is not), and check `port =` matches the real SSH port.

## A Docker port is reachable despite ufw

That's by design (firewall.md). Rebind to `127.0.0.1:` or use DOCKER-USER rules (ufw-docker), then confirm with `external-check.sh`.

## Caddy or certbot can't get a certificate

DNS doesn't point at the box yet (`dig +short example.com`), port 80 is closed (HTTP-01 needs it), Cloudflare is set to "Flexible", or there's an IPv6 AAAA record pointing somewhere else. Check `journalctl -u caddy -n 100`. Let's Encrypt rate limits apply to repeated failures; use the staging CA while debugging.

## Site unreachable after the Cloudflare allowlist

The sync didn't run or failed (`journalctl -u ufw-cloudflare-sync`), the record isn't proxied (grey cloud), or IPv6 rules are missing.

## apt hangs over SSH

It's waiting for a conffile question or the needrestart dialog. Use the non-interactive flags (base.md). If a dpkg run was interrupted: `dpkg --configure -a`.

## Disk full

`ncdu -x /`. The usual suspects: Docker logs or images (`docker system df`; daemon.json log limits), the journal (`journalctl --disk-usage`; journald cap), old kernels (`apt autoremove --purge`), backups dumped locally, core dumps.

## "Backup WARNING" or "Backup overdue"

WARNING means restic exit 3: a snapshot exists, but some files were unreadable (`journalctl -u vps-forge-backup` names them). Fix their permissions or exclude them in `/etc/restic/exclude`. "Backup FAILED" is a real failure (repository, credentials, an fstab volume that is not mounted). "Overdue" with no failure means the timer isn't running: `systemctl list-timers vps-forge-backup.timer`.

## Unattended upgrades never run

`systemctl list-timers 'apt-daily*'` shows the timers. `apt-config dump APT::Periodic::Unattended-Upgrade` should print "1". Logs are in `/var/log/unattended-upgrades/`.
