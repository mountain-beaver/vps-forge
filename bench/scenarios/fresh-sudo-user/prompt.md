I just bought this VPS: `ssh vps` logs me in as `{ssh_user}` with my SSH key. That user has sudo without a password; root login is disabled, the way the provider's image ships. Please turn it into a proper production server for my app:

- The app is the Docker image `traefik/whoami` (it listens on port 80 inside the container). It should be reachable on port 80 of the server. No domain yet, plain HTTP is fine for now.
- Its data lives in `/srv/app/data`.
- Make the server secure.
- Back up the app data every day to the extra volume mounted at `/mnt/backup`.
- Send alerts to my phone through my ntfy topic: `http://10.0.2.2:8099/vps-alerts`.

I'm going offline now and can't answer questions, so make reasonable decisions yourself and tell me at the end what you did and what I still need to do. You have my OK to change SSH and firewall settings, but I must still be able to log in with my key afterwards.
