# Script mode

## Contents
- When to use it
- The flow: recon, then one script per stage
- Getting files onto the server
- What every generated script does
- The test-and-disarm pause
- What script mode can't do

## When to use it

You can't reach the server yourself: a chat app with code execution but no outbound SSH, or a user who wants to run every command themselves. The safety rules don't change. What changes is that the user is your hands, so every step has to be safe to run without you watching, and every check has to print something the user can paste back.

Tell the user this up front, in one or two lines: they will run a few scripts in an SSH session, each one pauses before risky steps, and they paste the output back after each one.

## The flow: recon, then one script per stage

Never write the whole setup blind. A script that guesses the distro, the SSH unit or the firewall is how script mode locks people out.

When the user wants everything in one answer ("give me a script and the exact steps"), or the server is a fresh image they described (provider, distro, version), skip the recon round-trip but not the facts: each stage script starts by checking every assumption it was written for (distro and version, `ssh.socket` vs `ssh.service`, the firewall that is already there, Docker present or not) and stops before changing anything, with a clear message, if one doesn't hold.

1. **Recon.** Give the user `audit.sh` and one command: `sudo bash audit.sh --json > recon.json; sudo bash audit.sh`. Ask them to paste the human-readable output (it holds no secrets) or upload `recon.json`. Read it like phase 0: distro, OpenSSH version, socket activation, existing firewall, Docker, red flags. Stop here for the same reasons as phase 0 (a Kubernetes node, a hypervisor, a non-Debian/Ubuntu system, signs of compromise).
2. **Stage scripts.** Write one script per stage, each small enough for the user to read:
   - `1-base.sh`: safety net (etckeeper, deadman installed), packages, unattended upgrades, time, swap, journald (phases 1–2). Nothing here can cut off access.
   - `2-access.sh`: admin user and key, sudo policy, sshd drop-ins, firewall, fail2ban (phases 3–5). Every risky step sits inside a deadman window with the pause below.
   - `3-workload.sh`: kernel, Docker, web, backups, alerts, comfort, per the profiles (phases 6–10).
   - The final audit: `sudo bash audit.sh` again, pasted back, compared with recon (phase 11).
3. **Between stages,** read what the user pasted. If anything failed or looks unexpected, write a fix or the next script for the state the server is actually in. Don't hand over the next stage on top of a failed one.

## Getting files onto the server

Bundle what the stage needs into one archive: the stage script, `deadman.sh`, `audit.sh`, `install-alerts.sh` if alerts are in scope, and the templates from `assets/` with every `<placeholder>` already filled. Offer it as a download and give the user exactly these commands:

```bash
scp vps-forge-stage1.tar.gz <user>@<host>:
ssh <user>@<host>
tar xzf vps-forge-stage1.tar.gz && cd vps-forge
sudo bash 1-base.sh
```

On Windows without `scp`, PowerShell's built-in OpenSSH has it; otherwise `ssh <user>@<host> "cat > vps-forge-stage1.tar.gz" < vps-forge-stage1.tar.gz`. Don't ask the user to paste a long script into a terminal: one mangled line in a heredoc is a broken sshd config.

Tell them to run the stages from their own SSH session, not from the provider's web console. The scripts need the SSH client address for fail2ban's `ignoreip` and for the deadman's unban, and a console session has none. If they must use the console, the script asks for the IP they connect from (rule 2) and refuses an empty answer.

## What every generated script does

- Starts with `#!/usr/bin/env bash` and `set -Eeuo pipefail`, plus a `trap` on `ERR` that prints the failing line and "paste this output back to the agent".
- Refuses to run as anything but root, and on anything but the distro and version recon found (`/etc/os-release`).
- Checks state before each step and skips what is already done, so a rerun after a fix is safe. Appends `phase=<name> status=done` to `/var/lib/vps-forge/progress.log` after each one.
- Uses only non-interactive commands (SKILL.md §2), validates every file it writes (`sshd -t`, `visudo -cf`, `fail2ban-client -t`), and commits with etckeeper after each phase.
- Generates secrets on the server, mode 600, and prints where they are, never their values. At the end it tells the user which files to read once and store offline (the restic password, for example).
- Ends with a short summary block: what changed, what was skipped and why, and the next command to run.

## The test-and-disarm pause

This is the step that replaces your new-connection test. In `2-access.sh`, around every SSH, firewall, sudo or PAM change:

```bash
vps-forge-deadman arm 10
# ... the change, validated ...
cat <<MSG

Keep this window open. In a NEW terminal on your computer, run:
  ssh -o ControlPath=none -p ${PORT} ${ADMIN}@${HOST} 'sudo -n vps-forge-deadman disarm'
If it prints "disarmed: changes kept", you're done with this step: come back and press Enter.
If the login fails, do nothing. In 10 minutes the server undoes this step by itself.
MSG
read -r -t 540 -p "Press Enter after the new login disarmed it: " || true
st=$(vps-forge-deadman status)
case "$st" in
  ARMED*) echo "Still armed: the new login didn't disarm it. Stopping here; the rollback will run. Paste this output back."; exit 1 ;;
  *"ROLLED BACK since"*) echo "The server rolled this step back. Stopping here. Paste this output back."; exit 1 ;;
esac
```

The user's second terminal is the new connection: it can't reuse the session the script runs in. Under password sudo the test command is `ssh -t -o ControlPath=none -p ${PORT} ${ADMIN}@${HOST} 'sudo vps-forge-deadman disarm'`, and the user types their password there. Never let the script disarm itself: a disarm that didn't come from a new login proves nothing.

## What script mode can't do

Say these in the final report, not as fine print:
- You don't see the server, only what the user pastes. Anything the scripts didn't print, you can't vouch for.
- No outside-in check unless the user runs `bash external-check.sh <host>` on their own Mac or Linux machine. On Windows, ask them to run it in WSL, or give them the manual list: `ssh root@<host>` is refused, `ssh -o PubkeyAuthentication=no <admin>@<host>` is refused, and only the ports in SERVER.md answer.
- No reboot drill unless the user agrees to reboot and then runs the final audit.
