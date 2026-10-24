# Distribution notes

Always confirm on the box (`. /etc/os-release; echo $PRETTY_NAME; ssh -V; systemctl --version | head -1; systemd-detect-virt`). Versions below are what each release ships at GA. Point releases and backports can differ.

| | Ubuntu 22.04 | Ubuntu 24.04 | Debian 12 | Debian 13 |
|---|---|---|---|---|
| OpenSSH | 8.9 | 9.6 | 9.2 | 10.0 |
| SSH socket activation | no | **yes** (`ssh.socket`) | no | no |
| Post-quantum KEX | sntrup761 | sntrup761 | sntrup761 | **mlkem768 (default)** |
| sshd per-connection process name | sshd | sshd | sshd | **sshd-session** |
| fail2ban | 0.11.2 | 1.0.2 | 1.0.2 (needs `python3-systemd`) | 1.1.0 (Debian-patched for `sshd-session`) |
| rsyslog / auth.log | yes | yes | **no** (journal only) | **no** |
| `/tmp` | disk | disk | disk | **tmpfs** |
| Standard support | to 2027 | to 2029 | to mid-2026, then LTS | to 2028 |

## Ubuntu 24.04

- **SSH is socket-activated.** `ListenAddress` and `Port` changes need `systemctl daemon-reload && systemctl restart ssh.socket`; a plain `reload ssh` does not move the port. Other directives work with `reload ssh`.
- Early 24.04 fail2ban crashed on Python 3.12 (missing `asynchat`). Upgrade the package if you see that traceback.
- The needrestart dialog appears on every apt run unless `NEEDRESTART_MODE=a` is set or the conf drop-in is installed.

## Ubuntu 26.04 and newer

Treat it like 24.04, but **verify** rather than assume: check `ssh -V`, `ssh -Q kex`, `systemctl is-enabled ssh.socket`, and the fail2ban version. The skill's algorithm picker and checks are version-driven for this reason.

## Debian 12

- No `/var/log/auth.log`. fail2ban must use `backend = systemd` with `python3-systemd`.
- `sudo` and `ufw` may be missing on minimal and provider images. Install them first.
- Debian's own LTS covers 12 after standard support ends. Plan the upgrade to 13.

## Debian 13

- OpenSSH 10: DSA is gone entirely, and `mlkem768x25519-sha256` is the default KEX.
- Log lines come from `sshd-session`. Use Debian's fail2ban package (1.1.0-6+, patched for OpenSSH 9.8). A stock upstream 1.1.0 from pip or old backports won't match. Verify with `fail2ban-regex`.
- `/tmp` is tmpfs and cleaned on reboot. Don't put anything there that must persist.

## Older releases

Ubuntu 20.04 and Debian 11 are past standard support. Recommend a rebuild on a current release instead of hardening the old one. If the user can't rebuild, harden anyway and record the EOL risk as a High finding.

## Container-based VPS (OpenVZ, LXC, Virtuozzo)

Detect with `systemd-detect-virt` (`openvz` or `lxc`). Expect:
- No custom kernel, no Livepatch, no kernel modules (BBR may be unavailable), most sysctls read-only.
- Often no swap control. ufw may fail if the host doesn't expose the netfilter modules; fall back to the provider firewall.
- Docker inside may be impossible or require nesting to be enabled by the provider.
- Rootless Docker is a different case: it needs only user namespaces, and ufw does apply to its published ports (docker.md).

Tell the user these limits early. A KVM VPS is usually the same price and has none of them.

## ARM (Ampere, Graviton, Hetzner CAX)

Everything here works. Use `dpkg --print-architecture` in apt repo lines (already in docker.md), and check that the user's container images have `arm64` variants.

## Cloud providers with their own rules

- **Oracle Cloud (OCI).** Ubuntu images ship `iptables-persistent` rules (`/etc/iptables/rules.v4`) that end in a catch-all `REJECT`, so ufw's rules land after it and never match. Oracle also warns that ufw can remove the platform rules, which breaks the boot and block volume (iSCSI) connections on the next reboot. Keep the `169.254.0.0/16` rules. Open ports by inserting `ACCEPT` lines **before** the final `REJECT` in `/etc/iptables/rules.v4` (apply with `iptables-restore < /etc/iptables/rules.v4`; test it from a second session), or rely on the VCN security list and leave ufw off. Don't run `ufw enable` here without the user's explicit OK, and never `firewall-cmd --reload` on Oracle Linux.
- **AWS EC2.** There is no host-firewall tradition: access is controlled by Security Groups, so check them first when a port "doesn't work" (`ufw` is optional defense in depth, and changing the SSH port needs the Security Group updated too). EC2 Instance Connect injects a temporary key through `AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys` (user `ec2-instance-connect`). Keep those directives, and keep the default user (`ubuntu`, `admin`, `ec2-user`) in the `AllowGroups` group; otherwise `AllowGroups` refuses Instance Connect logins. Don't override `AuthorizedKeysCommand` in the vps-forge drop-in.
- **IPv6-only servers.** `github.com` has no AAAA record, so `git clone`, release downloads and anything else on GitHub fail without NAT64/DNS64 (the provider's DNS64 resolvers, or a public DNS64 service). Check `getent ahostsv6 github.com`; ::ffff: results are IPv4-mapped, not IPv6. apt mirrors, Docker's repository and Let's Encrypt do have IPv6.

## RHEL family (Rocky, Alma, CentOS Stream, Fedora)

Out of scope for this version. The principles carry over, but the tools differ: `firewalld`, `dnf-automatic`, SELinux (`semanage port` for SSH port changes), the service is named `sshd`, and system crypto-policies apply. Tell the user, follow the same phases and safety rules, and verify every command against the distro's docs.
