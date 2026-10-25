# Privacy

vps-forge collects nothing. It has no telemetry, no account and no server of its own.

The skill runs inside your AI agent and configures a server you own. What it sends, and where:

- **Commands go to your server**, over SSH, from wherever your agent runs.
- **Alerts go to the service you choose**: your ntfy topic, Telegram bot or webhook. The token you create stays on your server in a file only root can read, and is sent only to that service.
- **Backups go to the restic repository you choose.** An optional heartbeat goes to a URL you give it.
- **Packages come from your distribution's apt repositories**, plus the signed vendor repositories for the tools you pick: Docker, Caddy, Tailscale, CrowdSec.
- **TLS certificates come from Let's Encrypt**, through Caddy or certbot. The email address you give for expiry notices is stored in your web server's config and sent to Let's Encrypt.
- **Cloudflare's published IP list** is fetched from cloudflare.com, only if your site is behind Cloudflare.
- **The outside-in check** runs on your own machine and connects only to your own server and domain.

Your AI agent's provider sees the conversation and the command output, as it does for any other task. That is governed by the provider's own privacy terms, not by this project.

Questions: open an issue at https://github.com/mountain-beaver/vps-forge/issues.
