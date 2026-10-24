#!/usr/bin/env bash
# Run a command in its own network + mount namespace (rootless, via pasta).
#  - public DNS: QEMU's user-mode network reads /etc/resolv.conf directly, and the host's
#    127.0.0.53 stub resolver is not reachable from a separate network namespace;
#  - a clean ssh_config: root-owned files look unowned inside the user namespace, and OpenSSH
#    refuses to read the host's;
#  - the home directory is read-only except the paths in POD_RW (default: the runs directory).
#    This protects the host from the harness. The agent under test runs one level deeper, in
#    cell.py's bubblewrap jail: there the real home is not even visible, only the run's private
#    home and work dir (and the frozen skill, read-only). Its Claude login is a read-only copy
#    (cell.py private_login), so the user's own login file is never writable from a pod.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export POD_HOST_UID="$(id -u)"
export POD_RW="${POD_RW:-$HOME/.cache/vps-forge-bench/runs}"
# -t/-u/-T/-U none: no automatic port forwarding between the namespace and the host, so VM
# ports never appear on the host (or the LAN), and parallel pods cannot clash.
exec pasta --config-net --quiet -t none -u none -T none -U none -- unshare -m bash -c '
  set -e
  mount --bind "$1" "$(readlink -f /etc/resolv.conf)"
  mount --bind "$2" "$(readlink -f /etc/ssh/ssh_config)"
  h=$HOME
  mount --rbind "$h" "$h"
  mount -o remount,bind,ro "$h"
  IFS=: read -r -a rws <<< "$POD_RW"
  for rw in "${rws[@]}"; do
    [ -d "$rw" ] || continue
    mount --bind "$rw" "$rw"
    mount -o remount,bind,rw "$rw"
  done
  # the orchestrating session keeps its notes under /tmp/claude-<uid>: read-only as well
  t="/tmp/claude-$POD_HOST_UID"
  if [ -d "$t" ]; then mount --bind "$t" "$t" && mount -o remount,bind,ro "$t"; fi
  shift 2
  exec "$@"' pod "$here/resolv.conf" "$here/ssh_config" "$@"
