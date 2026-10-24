#!/usr/bin/env bash
# Starting state: a small shop that has been running for a while. Runs as root inside the VM.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io ufw >/dev/null
systemctl enable --now docker >/dev/null 2>&1

mkdir -p /srv/shop/db /srv/shop/uploads
for i in $(seq 1 20); do echo "order $i" > "/srv/shop/uploads/invoice-$i.txt"; done

docker pull -q traefik/whoami >/dev/null
docker pull -q postgres:16-alpine >/dev/null
docker pull -q adminer >/dev/null
docker run -d --name shop --restart unless-stopped -p 80:80 traefik/whoami >/dev/null
docker run -d --name db --restart unless-stopped -p 5432:5432 \
  -e POSTGRES_PASSWORD=shop123 -e POSTGRES_DB=shop -v /srv/shop/db:/var/lib/postgresql/data postgres:16-alpine >/dev/null
docker run -d --name adminer --restart unless-stopped -p 8081:8080 adminer >/dev/null

# The owner "secured" the box with ufw: only SSH and web. Docker bypasses it.
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw --force enable >/dev/null

# Legacy SSH settings and a forgotten contractor key.
printf 'PermitRootLogin yes\n' > /etc/ssh/sshd_config.d/60-legacy.conf
ssh-keygen -q -t ed25519 -N '' -C old-contractor@laptop -f /root/contractor-key
cat /root/contractor-key.pub >> /root/.ssh/authorized_keys
rm -f /root/contractor-key /root/contractor-key.pub
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# Automatic updates were switched off "because they broke something once".
printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades

# Wait until the shop answers.
for _ in $(seq 1 30); do curl -fs http://127.0.0.1/ >/dev/null && break; sleep 2; done
curl -fs http://127.0.0.1/ >/dev/null
