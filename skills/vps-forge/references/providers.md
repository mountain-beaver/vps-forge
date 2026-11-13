# Provider notes

Where each provider keeps its web console, how to take a snapshot, and how to add one firewall rule without touching the others. Panel menus move around: if a path below doesn't match, search the provider's docs for the feature name rather than guessing. CLI commands run on the user's machine with their credentials and their consent.

## Contents
- The two rules for provider firewalls
- Hetzner Cloud
- DigitalOcean
- Vultr
- Linode (Akamai)
- OVHcloud
- AWS EC2
- AWS Lightsail
- Oracle Cloud (OCI)

## The two rules for provider firewalls

The dead-man switch only restores files on the server, so nothing undoes a wrong provider rule (firewall.md "Provider firewall").
1. **Add, prove, remove.** Add the new rule, prove a login over a new connection, and only then delete the old rule.
2. **Never replace the rule set.** Some commands rewrite the whole list in one call (named below for each provider). One missing line in that list locks the user out.

## Hetzner Cloud

- **Console:** the server's page, console icon at the top right. It logs in with root's password; without one, Rescue → Reset root password. The rescue system (Rescue → Enable rescue & power cycle) boots a live Linux with the disk attached.
- **Snapshot:** Snapshots → Take snapshot, or `hcloud server create-image --type snapshot --description pre-hardening <server>`. Snapshots don't include attached Volumes.
- **Firewall, one rule:** `hcloud firewall add-rule <firewall> --direction in --protocol tcp --port <port> --source-ips <cidr>` (`0.0.0.0/0` and `::/0` for anyone). Never `hcloud firewall replace-rules`. With no inbound rules a Hetzner firewall drops all inbound traffic; existing connections survive rule changes.

## DigitalOcean

- **Console:** Droplet → Web Console (the Droplet agent; no password needed). It connects to the **first** `Port` in `sshd_config`, so after a port change it needs the agent's config updated too, and the cloud firewall must allow the SSH port. The older Recovery Console (Droplet → Settings) needs a root password; "Reset root password" mails a temporary one.
- **Snapshot:** Backups & Snapshots → Take snapshot (powered off is more consistent), or `doctl compute droplet-action snapshot <droplet-id> --snapshot-name pre-hardening --wait`.
- **Firewall, one rule:** Networking → Firewalls → the firewall → Rules, or `doctl compute firewall add-rules <firewall-id> --inbound-rules "protocol:tcp,ports:<port>,address:<cidr>"`. Never `doctl compute firewall update`: it replaces the rules and resets what you leave out.

## Vultr

- **Console:** the instance → View Console (noVNC). Paste the root password from the Overview tab through the noVNC clipboard menu; typing it is error-prone.
- **Snapshot:** the instance → Snapshots → Take Snapshot, or `vultr-cli snapshot create --id <instance-id> --description pre-hardening`. It can take up to 30 minutes.
- **Firewall, one rule:** Network → Firewall → the group → Add Firewall Rule (IPv4 and IPv6 are separate lists), or `vultr-cli firewall rule create --id <group-id> --ip-type v4 --protocol tcp --port <port> --subnet <ip> --size <prefix-length>`. Rules are added and deleted one by one; there is no replace command.

## Linode (Akamai)

- **Console:** the Linode → Launch LISH Console. Weblish needs a password for an account on the server; Lish over SSH (`ssh <cloud-manager-user>@lish-<region>.linode.com`) uses the Cloud Manager login.
- **Snapshot:** the Linode → Backups → Manual Snapshot. It needs the paid Backups service, and there is only one manual snapshot: a new one replaces the old.
- **Firewall, one rule:** Firewalls → the firewall → Rules → Add An Inbound Rule, then **Save Changes** (nothing applies before that). Use the panel: the CLI's `linode-cli firewalls rules-update` replaces both rule lists, so a rule added that way means sending every existing rule too.

## OVHcloud

- **Console:** the VPS → General information → "…" next to its name → KVM. Check the keyboard layout before typing a password. Rescue mode (Home → "…" next to Boot) mails a temporary root password.
- **Snapshot:** the VPS → Home → Backup → Snapshot. It is a paid option, holds one snapshot at a time, and restoring deletes it.
- **Firewall, one rule:** VPS and dedicated servers use the Edge Network Firewall on the IP (Network → Public IP Addresses → "…" → Configure Edge Network Firewall): IPv4 only, up to 20 rules per IP by priority, and it needs a final deny rule to block anything. Public Cloud instances use OpenStack security groups: `openstack security group rule create --protocol tcp --dst-port <port> --remote-ip <cidr> <group>` adds one rule.

## AWS EC2

- **Console:** EC2 Serial Console (instance → Actions → Monitor and troubleshoot → EC2 Serial Console). It is off by default for each account and Region (`aws ec2 enable-serial-console-access`), and it needs an OS user with a password: AWS images have none, so set one before you depend on it.
- **Snapshot:** `aws ec2 create-image --instance-id <id> --name pre-hardening` (reboots the instance for consistency unless `--no-reboot`), or `aws ec2 create-snapshot --volume-id <vol>` for one volume.
- **Firewall, one rule:** Security Groups → the group → Edit inbound rules → Add rule → Save rules, or `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port <port> --cidr <cidr>`. Remove the old one last with `revoke-security-group-ingress`. Security groups have no host-firewall tradition behind them: check them first when a port "doesn't work".
- **Default users:** `ubuntu` (Ubuntu), `admin` (Debian). EC2 Instance Connect injects a temporary key through `AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys` (user `ec2-instance-connect`). Keep those directives and keep the default user in the `AllowGroups` group, or Instance Connect logins are refused. Don't override `AuthorizedKeysCommand` in the vps-forge drop-in.

## AWS Lightsail

- **Console:** the browser SSH on the instance's Connect tab. It needs port 22 open, or "Allow Lightsail browser SSH/RDP" ticked on a restricted SSH rule; there is no serial console.
- **Snapshot:** the instance → Snapshots → Create snapshot, or `aws lightsail create-instance-snapshot --instance-name <name> --instance-snapshot-name pre-hardening`.
- **Firewall, one rule:** Networking → IPv4 Firewall (and the separate IPv6 Firewall) → Add rule, or `aws lightsail open-instance-public-ports --instance-name <name> --port-info fromPort=<port>,toPort=<port>,protocol=TCP`. Never `put-instance-public-ports`: it closes every port it doesn't list. Rules are allow-only and the most permissive one wins, so a leftover "SSH from anywhere" rule overrides a restricted one.

## Oracle Cloud (OCI)

- **Console:** the instance → Console connection → Launch Cloud Shell connection (serial). Logging in there needs an OS user with a password, and OCI sets none for the default user.
- **Snapshot:** `oci bv boot-volume-backup create --boot-volume-id <ocid> --display-name pre-hardening` (incremental by default).
- **Firewall, one rule:** traffic must pass the subnet's security list, any network security group (NSG) on the VNIC, and the OS firewall. For an NSG, `oci network nsg rules add --nsg-id <ocid> --security-rules file://rule.json` adds rules, with `rule.json` as `[{"direction":"INGRESS","protocol":"6","source":"<cidr>","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":<port>,"max":<port>}}}]`. For a security list use the panel (Networking → Virtual Cloud Networks → the VCN → Security Lists → Add Ingress Rules): `oci network security-list update` replaces the whole list.
- **The OS firewall:** Ubuntu images ship `iptables-persistent` rules (`/etc/iptables/rules.v4`) that end in a catch-all `REJECT`, so ufw's rules land after it and never match. Oracle also warns that ufw can remove the platform rules, which breaks the boot and block volume (iSCSI) connections on the next reboot. Keep the `169.254.0.0/16` rules. Open ports by inserting `ACCEPT` lines **before** the final `REJECT` in `/etc/iptables/rules.v4` (apply with `iptables-restore < /etc/iptables/rules.v4`; test it from a second session), or rely on the VCN rules and leave ufw off. Don't run `ufw enable` here without the user's explicit OK, and never `firewall-cmd --reload` on Oracle Linux.
