# VPN profile and private admin access

## Contents
- Choosing: Tailscale vs WireGuard
- Tailscale
- WireGuard server
- SSH only over the VPN (paranoid)

## Choosing

- **Tailscale** (or self-hosted Headscale): the easiest way to put admin access, databases and dashboards on a private network. No open port is needed, NAT traversal is built in, and access is controlled by ACLs. Best for "only I and my laptop should reach this".
- **WireGuard** directly: full control, no third party, and the right choice for "I want my own VPN to route my traffic through". It needs one UDP port and key management. For a GUI, `wg-easy` (Docker) is popular.

## Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh     # official script; show it to the user first
tailscale up --timeout=60s                            # prints a login URL; the USER opens it. A timeout means "not logged in yet", not success.
tailscale status --json | jq -r .BackendState         # must print Running before any rule depends on the tailnet; if NeedsLogin, hand over the URL and wait
tailscale ip -4
ufw allow in on tailscale0 comment 'tailnet'
```
- Exit node: needs `net.ipv4.ip_forward=1` (and `net.ipv6.conf.all.forwarding=1`), `rp_filter=2` (kernel.md), `tailscale up --advertise-exit-node`, and approval in the admin console.
- Subnet router: same forwarding and `rp_filter`, `tailscale up --advertise-routes=10.0.0.0/24`, approve the route in the admin console, and clients run `tailscale up --accept-routes`.
- `tailscale up --ssh` lets Tailscale handle SSH auth through tailnet ACLs. It's a valid alternative to keys, but it moves trust to the Tailscale account. Make sure the user understands that before enabling it.
- Turn on key expiry and MFA on the identity provider. The tailnet is now part of the server's perimeter.

## WireGuard server

```bash
$APT install wireguard qrencode
umask 077; wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
```
`/etc/wireguard/wg0.conf`:
```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <contents of server.key>

[Peer]
# laptop
PublicKey = <client public key>
AllowedIPs = 10.8.0.2/32
```
- **Client keys belong on the client.** Have the user run `wg genkey | tee c.key | wg pubkey` on their device and send you only the public key. For phones, where that's awkward, generate on the server, show the QR (`qrencode -t ansiutf8 < client.conf`), then **delete** the client's private key from the server.
- Firewall and forwarding for "route all my traffic through the VPS":
  ```bash
  ufw allow 51820/udp comment 'wireguard'
  ufw route allow in on wg0 out on <wan-if> comment 'wg egress'
  # top of /etc/ufw/before.rules, before the *filter section:
  #   *nat
  #   :POSTROUTING ACCEPT [0:0]
  #   -A POSTROUTING -s 10.8.0.0/24 -o <wan-if> -j MASQUERADE
  #   COMMIT
  ```
  Also set `net.ipv4.ip_forward = 1` and `rp_filter = 2` in the sysctl file. Find `<wan-if>` with `ip route show default`.
- Start it: `systemctl enable --now wg-quick@wg0`. A recent handshake in `wg show` only proves the keys and the UDP path, not routing: from the client, `ping 10.8.0.1` and `curl -s https://ifconfig.me` must return the VPS IP; on the server, `sysctl net.ipv4.ip_forward` is 1 and `iptables -t nat -L POSTROUTING -n -v` shows the MASQUERADE rule. Only then call it working. For server-only access, the ping is the test.
- For access to the server only (no traffic routing), skip NAT and forwarding and just `ufw allow in on wg0`.

## SSH only over the VPN (paranoid)

This removes SSH from the internet entirely. Do it only after the VPN path has been proven, and always with the deadman. The deadman restores the firewall rules below, but it doesn't snapshot WireGuard, Tailscale or netplan config, so never point the server's own default route into a tunnel (`AllowedIPs = 0.0.0.0/0` on the server, `tailscale up --exit-node=…`):
1. From the user's machine: `ssh <admin>@<vpn-ip>` works (`100.x.y.z` on Tailscale, `10.8.0.1` on WireGuard).
2. `vps-forge-deadman arm 10`
3. Delete both public SSH rules: `ufw delete limit <port>/tcp` and `ufw delete allow from <admin-ip> to any port <port> proto tcp` (plus any other admin or agent-session allow for that port; check `ufw status`). Keep `ufw allow in on tailscale0` or `ufw allow in on wg0 to any port <port> proto tcp`.
4. The public IP no longer answers on the SSH port (`external-check.sh`, or `nc -z -w 5 <public-ip> <port>` fails). A leftover admin rule would still let the admin in from outside.
5. Test and disarm over the VPN (ssh.md "Test and disarm", with `<admin>@<vpn-ip>`; `ControlPath=none` so a multiplexed master over the public IP can't fake it). Write in SERVER.md that **break-glass access is the provider console only** if the VPN breaks. Also mirror the rule in the provider firewall.
