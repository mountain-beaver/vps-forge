# Kernel and OS hardening

## Contents
- sysctl
- When NOT to apply a setting
- BBR
- AppArmor
- Unused services
- Paranoid extras: auditd, AIDE, /dev/shm, core dumps, rare protocols

## sysctl

Copy `assets/sysctl/99-vps-forge.conf` to `/etc/sysctl.d/` (for sysctl the **last** file wins, so `99-` is correct here), adjust it per profile, then:
```bash
sysctl --system 2>&1 | grep -iE 'error|invalid|unknown' || echo OK
# conf.all/conf.default don't change interfaces that are already up for these keys (the kernel
# ORs the per-interface value in), so apply them to the live interfaces too, or reboot:
for k in accept_redirects send_redirects accept_source_route; do
  for f in /proc/sys/net/ipv4/conf/*/$k; do echo 0 > "$f"; done
done
for f in /proc/sys/net/ipv6/conf/*/accept_redirects /proc/sys/net/ipv6/conf/*/accept_source_route; do echo 0 > "$f"; done
sysctl net.ipv4.tcp_congestion_control kernel.kptr_restrict net.ipv4.conf.all.rp_filter
```
What the file does, so you can explain it:
- **Network:** SYN cookies (SYN-flood resilience), reverse-path filtering (drops spoofed source addresses), no ICMP redirects or source routing (a router-level attack surface a VPS never needs), ignore broadcast pings.
- **Kernel info leaks:** `kptr_restrict=2` and `dmesg_restrict=1` hide kernel addresses and logs from unprivileged users. `yama.ptrace_scope=1` stops a process from attaching to processes it didn't start (Debian's default is 0).
- **Filesystem:** `protected_{hardlinks,symlinks,fifos,regular}` blocks classic `/tmp` race attacks. `suid_dumpable=0` stops setuid programs from dumping memory.
- **Memory:** `vm.swappiness=10` keeps hot memory in RAM.

What each group costs. Say it in one line when you apply the file on a box where the user debugs or profiles, and write it into SERVER.md:
- **Network:** nothing on a single-homed server. Asymmetric routing is the exception (next section).
- **`kptr_restrict=2`:** kernel addresses read as zeros **even for root**, so `perf` and `bpftrace` lose kernel symbols under `sudo` too. While profiling, `sysctl -w kernel.kptr_restrict=1` shows them to root again and `audit.sh` still passes it.
- **`dmesg_restrict=1`:** `dmesg` needs `sudo`. Most distros already default to this.
- **`yama.ptrace_scope=1`:** `strace -p`, `gdb -p` and similar attach tools, such as py-spy, fail without `sudo` on a process they didn't start. Starting a program under `strace` still works, and root (`CAP_SYS_PTRACE`) can attach to anything.
- **`protected_fifos=2`, `protected_regular=2`:** in a sticky world- or group-writable directory such as `/tmp`, opening a file or FIFO with `O_CREAT` is refused when it already exists and belongs to another user. Rare; it shows up as root getting "Permission denied" writing to a user's file in `/tmp`.
- **`suid_dumpable=0`, `swappiness=10`, BBR:** no practical cost.

To relax one setting, never delete the whole file. troubleshooting.md "A tool broke after the kernel hardening" has the procedure. A setting the user relaxed (in `/etc/sysctl.d/99-zz-local.conf`, or noted in SERVER.md) is their choice: keep it on later runs, don't offer to revert it, and explain the `kernel.sysctl` WARN it causes instead of fixing it.

## When NOT to apply a setting

- **VPN gateway, Tailscale exit node or subnet router, or multi-homed host:** use `rp_filter = 2` (loose). Strict mode drops legitimate asymmetric traffic, and Tailscale warns about it.
- **Docker or VPN:** never set `net.ipv4.ip_forward = 0`. Docker and WireGuard need forwarding. Docker turns it on itself; vpn.md covers WireGuard.
- **IPv6 via router advertisements:** don't touch `accept_ra`. Most VPS get their IPv6 default route from RAs, and disabling them silently kills IPv6.
- **Container VPS (OpenVZ/LXC):** most sysctls are read-only. Errors from `sysctl --system` are expected there. Report what couldn't be applied, and don't fight it.

## BBR

BBR congestion control noticeably improves throughput on lossy and long-distance links (users far from the server, VPN tunnels). It's built into every supported kernel:
```bash
modprobe tcp_bbr 2>/dev/null; sysctl net.ipv4.tcp_available_congestion_control   # must list bbr
```
The sysctl file sets `net.core.default_qdisc = fq` and `net.ipv4.tcp_congestion_control = bbr`. If BBR isn't available (some container VPS types), remove those two lines.

## AppArmor

It's enabled by default on Debian and Ubuntu. Verify with `aa-status | head -n 5`, or with `cat /sys/module/apparmor/parameters/enabled` (prints `Y`). Docker applies its `docker-default` profile automatically. If AppArmor is disabled on a KVM VPS, the kernel command line usually has `apparmor=0`. Ask before changing GRUB.

## Unused services

```bash
systemctl list-units --type=service --state=running --no-pager
ss -H -tulpn
```
For each running service, ask "does this server need it?". Typical candidates on a VPS:
- `rpcbind` and `nfs-*`, unless NFS is in use
- `avahi-daemon` and `cups*` (rare on cloud images, common on hand-installed ones)
- `exim4` or `postfix` listening on a public interface: switch to localhost-only, or remove if nothing sends mail
- `snapd` on Ubuntu: removable if no snaps are used (`snap list`). It's opinionated, so ask, and don't remove it if LXD or a snap-based app exists.
- Provider agents (DigitalOcean `droplet-agent`, monitoring agents): ask. Some power console features.

Disable with `systemctl disable --now <unit>`. Purge only with the user's OK.

## Paranoid extras

Each of these has a real cost. Offer them, explain the cost, and apply only what the user accepts.

- **auditd:** `apt-get install auditd`, then load a rules file that watches identity and privilege files (`/etc/passwd`, `/etc/shadow`, `/etc/sudoers*`, `/etc/ssh/sshd_config*`) and `execve` by uid 0. Cost: log volume. Query with `ausearch -k <key>`.
- **AIDE** (file integrity): `apt-get install aide && aideinit` (takes minutes), then copy the new database into place as the installer prints. A daily check runs via `dailyaidecheck`. Pipe its output to `vps-notify`. Cost: you must re-baseline after every legitimate change. Run `aide --update` after upgrades.
- **/dev/shm noexec:** the fstab line `tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0`, then `mount -o remount /dev/shm`. Cost: rare apps break, mostly browsers or JITs in containers.
- **Core dumps off:** `/etc/systemd/coredump.conf.d/vps-forge.conf` with `[Coredump]` `Storage=none` and `ProcessSizeMax=0`, plus `/etc/security/limits.d/vps-forge.conf` with `* hard core 0`.
- **Rare network protocols:** `/etc/modprobe.d/vps-forge-blacklist.conf` with `install dccp /bin/false`, `install sctp /bin/false`, `install rds /bin/false` and `install tipc /bin/false`. These modules are the source of several historical local root exploits. Skip `sctp` if the user runs WebRTC or telecom software that needs it.
- **Scheduled reboots:** with Livepatch absent, set `Unattended-Upgrade::Automatic-Reboot "true"` and a time window (base.md).
