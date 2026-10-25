# Documentation and reproducibility

## SERVER.md

Fill `assets/SERVER.md` and save it as `/root/SERVER.md` (600). Give the user a local copy. Build the facts from the server, not from memory:
```bash
ufw status verbose; ss -H -tulpn; docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|allowgroups) '
git -C /etc log --oneline | head -n 30        # what vps-forge changed, phase by phase
systemctl list-timers --no-pager
```
Every listening port and every firewall rule gets a one-line reason. If you can't explain a port, it's a finding, not a documentation gap.

## Export: make the next server identical

Offer one of these at the end. Both describe the same state; pick whichever the user is more likely to maintain.

### cloud-init user-data (simplest)

Start from `assets/cloud-init.yaml` and fill it from the actual changes. `git -C /etc diff --stat <baseline-commit> HEAD` lists the files that changed, and each one becomes a `write_files` entry, **except** the deny-list below. Most VPS providers accept user-data at creation, so the next box boots already hardened. Rules:
- **Never export** (deny-list; skip these even when `git diff` lists them): `shadow*`, `gshadow*`, `passwd*`, `group*`, `subuid*`, `subgid*`, `ssh/ssh_host_*`, `restic/*`, `vps-forge/*` (`notify.env`), `sudoers.d/90-*`, `machine-id`, `hostname`, `hosts`, `fstab`, `ufw/user*.rules`, `.git*`. They hold secrets or identify one machine, and copying account files breaks the next box.
- **The SSH crypto drop-in is generated, not copied.** KEX and cipher names differ between OpenSSH versions (a file from Debian 13 makes `sshd` on Ubuntu 22.04 exit 255). Generate `01-vps-forge-crypto.conf` in `runcmd` on the target from its own `ssh -Q kex`, `ssh -Q cipher` and `ssh -Q mac` (the picker in ssh.md), then validate it and drop it if sshd rejects it: `sshd -t || rm -f /etc/ssh/sshd_config.d/01-vps-forge-crypto.conf`. A missing drop-in falls back to OpenSSH's defaults, which is safe; a broken one is not.
- **`<admin-ip>` is the user's own IP or range**, never an IP from an agent session (firewall.md, "The admin's IP").
- **No secrets** in user-data: providers store it, and it's readable from the instance metadata service. Leave placeholders and a comment saying where each secret comes from.
- Keep the deadman logic out of it. At first boot there's no live session to lose.
- Validate with `cloud-init schema --config-file cloud-init.yaml` when cloud-init is installed locally (or on the server: `cloud-init schema -c <file>`).

### Ansible (for people with more than one server)

Produce a small playbook with one role per phase (`base`, `ssh`, `firewall`, `fail2ban`, `sysctl`, `docker`, `caddy`, `backups`, `alerts`), using the same templates as `assets/`. Variables go in `group_vars/` and secrets in `ansible-vault`. Use only modules from `ansible.builtin` and `community.general` (`ufw` lives there).

### Where it goes

Suggest an `infra/` folder in the user's own git repo (`infra/<hostname>/SERVER.md`, `cloud-init.yaml` or `ansible/`). Never put `/etc/.git`, `/etc/restic/*` or `.env` files there.
