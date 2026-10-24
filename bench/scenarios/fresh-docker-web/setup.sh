#!/usr/bin/env bash
# Starting state: a brand-new VPS with an extra volume for backups. Runs as root inside the VM.
set -euo pipefail
dev=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E '/dev/(vd|sd)b$' | head -n 1)
[[ -n "$dev" ]] || { echo "no second disk" >&2; exit 1; }
mkfs.ext4 -q -L backup "$dev"
mkdir -p /mnt/backup
echo "LABEL=backup /mnt/backup ext4 defaults,nofail 0 2" >> /etc/fstab
mount /mnt/backup
mkdir -p /srv/app/data
for i in $(seq 1 50); do head -c 2048 /dev/urandom | base64 > "/srv/app/data/upload-$i.txt"; done
