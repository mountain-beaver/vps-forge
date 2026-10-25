# vps-forge

Set up, harden and audit a Debian or Ubuntu VPS without locking yourself out.

Ask Claude to put your app on a new server, secure an existing one, or check one you already run. The skill takes it through the whole job in the right order: an admin user with your key, root and password logins off, modern SSH crypto, a default-deny firewall that also covers Docker, fail2ban that never bans you, unattended security updates, Caddy or nginx with TLS, restic backups with a restore test, and phone alerts. It ends with a `SERVER.md` on the server that explains every open port.

Every SSH, firewall, sudo or PAM change runs inside a dead-man switch. The config is snapshotted and a 5-minute timer is armed. Claude then has to log in again over a fresh connection before it may disarm the timer. If that login fails, the change rolls back by itself, at boot too if the server restarts. A firewall in your provider's panel is outside the server, so the switch can't undo it; Claude adds the new rule there first and removes the old one only after a new login works.

On a server that is already in production, Claude audits first, read-only, and changes nothing until you approve.

Supported: Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04, on any provider.

## Install

Add it from the directory on claude.ai, or in Claude Code:

```
/plugin install vps-forge --marketplace mountain-beaver/vps-forge
```

Then just talk about your server: "I just bought a VPS at 203.0.113.10 and log in as root. Make it a proper production server for my Docker app, with backups and alerts to my phone."

## What it runs, and where data goes

- **On your server, as root over SSH.** In Claude Code the commands run from your machine with your own SSH key. What the skill writes, such as the admin user's name, its public key and your contact email for certificates, stays in your server's config. In a chat app that can't reach your server, the skill writes a guarded `setup.sh` for you to run instead.
- **Packages** come from the distribution's repositories, plus the vendors' signed apt repositories for the tools you choose: Docker, Caddy, Tailscale, CrowdSec.
- **Alerts** go only to the ntfy topic, Telegram bot or webhook you set up, with a token you create. It is stored on the server with mode 600 and is sent only to that service.
- **Backups** go only to the restic repository you choose. A heartbeat goes to the URL you give it, such as a healthchecks.io check, if you set one.
- **TLS certificates** come from Let's Encrypt, through Caddy or certbot. The email address you give for expiry notices is stored in the web server's config on your server and sent to Let's Encrypt.
- **The Cloudflare IP list** is fetched from cloudflare.com, only if you put the site behind Cloudflare.
- **A check from outside** runs on your machine and connects only to your own server and domain.

There is no telemetry. Nothing is sent anywhere else.

## Before you run it

Take a provider snapshot and find your provider's web console (VNC or serial). The first time, try it on a throwaway server.

Source, benchmark and full documentation: https://github.com/mountain-beaver/vps-forge
