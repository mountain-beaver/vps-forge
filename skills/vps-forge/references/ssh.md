# Admin user and SSH

## Contents
- Order of operations
- Test and disarm
- Admin user and sudo policy
- The sshd drop-in trap (read this)
- Baseline sshd config
- Hardened crypto (hardened+)
- Changing the port
- FIDO2 keys and TOTP (paranoid)
- Cleaning up what the provider left
- Hand-off cleanup (phase 12)
- Verification and client config

## Order of operations

The most common way to brick a VPS is to disable root or password login before the replacement path has been proven. Follow this order exactly:

1. As root (or the provider's default user): create the admin user and install the key.
2. `vps-forge-deadman arm 5`, write the sudo policy (below), then test and disarm (next section). This proves the admin login and sudo before anything depends on them.
3. `vps-forge-deadman arm 5`
4. Write `/etc/ssh/sshd_config.d/00-vps-forge.conf`, plus `01-vps-forge-crypto.conf` for `hardened` and above (the default level, see "Hardened crypto"). Run `sshd -t`, then `systemctl reload ssh`. Both files go into one deadman window and one test.
5. Test and disarm again. Also check that `ssh root@host` and password auth are refused.
6. `etckeeper commit "vps-forge: ssh hardening"`. If disarm exits non-zero and prints `ROLLED BACK` or `ROLLBACK IN PROGRESS`, the timer already fired and the change is gone: don't report it as applied, and don't commit.

If a test fails, don't improvise fixes through the old session while the timer is running. Let it roll back, then read `troubleshooting.md`.

## Test and disarm

The test runs from a **new, unmultiplexed** connection. Without `-o ControlPath=none`, ssh reuses the multiplexed master and proves nothing. Which command to use depends on the sudo policy:

- **NOPASSWD, or password sudo with the temporary grant** (below). One command proves the login, port, firewall and sudo, and disarms:
  `ssh -o ControlPath=none -o BatchMode=yes -p <port> <admin>@<host> 'sudo -n vps-forge-deadman disarm'`
  If it fails at any point, the switch stays armed and the timer rolls back.
- **Password sudo without the grant.** `sudo -n` always fails here, so it can't be the disarm path. Run `ssh -o ControlPath=none -o BatchMode=yes -p <port> <admin>@<host> 'sudo -n -v'`. It must fail with `a password is required`, which proves the login and that sudoers lets the admin in. `Sorry, user … may not run sudo` means the policy is broken: let the change roll back. Don't use `sudo -n true` for this: it prints `a password is required` for non-sudoers too. Also check in the root session that `passwd -S <admin>` shows `P` (a password is set); with `L` the admin can never pass sudo. When both pass, run `vps-forge-deadman disarm` from the existing root session. Once that session is gone, the user has to run `sudo vps-forge-deadman disarm` themselves.

## Admin user and sudo policy

```bash
U=<admin>
id "$U" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$U"
groupadd -f sshusers && usermod -aG sudo,sshusers "$U"
install -d -m 700 -o "$U" -g "$U" /home/$U/.ssh
# append the user's PUBLIC key (never a private key), then:
chmod 600 /home/$U/.ssh/authorized_keys && chown "$U:$U" /home/$U/.ssh/authorized_keys
```
If root already has the user's key, copy **only that key**, never the whole file. Old contractors' keys and provider keys often sit in root's file, and copying the file would hand them the new sudo account. List the keys with `ssh-keygen -lf /root/.ssh/authorized_keys`. The key the user connects with right now is the one in `journalctl -u ssh -g 'Accepted publickey' -n 5` (match the fingerprint). Copy just `type base64 comment` from that line. Cloud images prefix root's keys with options such as `no-port-forwarding,…,command="echo 'Please login as…';exit 142"`, and a copied prefix breaks the admin login:
```bash
B='<base64 body of that key>'
awk -v b="$B" '{ for (i = 2; i <= NF; i++) if ($i == b) { s = $(i-1) " " $i; for (j = i+1; j <= NF; j++) s = s " " $j; print s; exit } }' \
  /root/.ssh/authorized_keys > /home/$U/.ssh/authorized_keys
ssh-keygen -lf /home/$U/.ssh/authorized_keys   # same fingerprint as the journal line
```
Ask about every other key (see "Cleaning up what the provider left").

**The user logs in as root today?** At `hardened` and above, still create an admin user and move them off root. Use the name they asked for, otherwise `admin`. Copy only their key as above, prove the admin login and sudo from a new connection, and only then set `PermitRootLogin no`. A root login is one stolen key away from the whole box, and root's `authorized_keys` is exactly where forgotten keys pile up. Don't do this when the user explicitly says root must stay, for example for a deploy tool. Then keep `PermitRootLogin prohibit-password` and say why in SERVER.md. Put the new login command at the top of the final report: `ssh <admin>@<host>`.

**Root has deploy keys?** Check with `ssh-keygen -lf /root/.ssh/authorized_keys | grep -iwE 'deploy|ci|github|gitlab|actions|runner'`. A hit usually means a pipeline logs in as root, and `PermitRootLogin no` would silently break the next deploy. Don't turn root login off without the user's explicit OK, even if they approved the standard steps offline. Keep `prohibit-password` for now and offer a `deploy` user in `sshusers` with that key, with sudo limited to the commands the pipeline runs. Say so in the final report.

**Sudo policy is the user's decision.** Explain the trade-off and let them choose:

- **Password sudo (more secure).** A stolen key alone doesn't give root. The catch is that an agent can't type the password. Set it from the **root** session, before root login goes off: the admin can't run `sudo passwd` without a password it doesn't have yet. Either the user types it (`ssh -t root@<host> passwd <admin>` from their terminal), or you generate it into a file only the admin can read. This prints nothing, so the password never lands in the chat:
  ```bash
  install -m 600 -o "$U" -g "$U" /dev/null "/home/$U/SUDO-PASSWORD"
  PW=$(head -c 18 /dev/urandom | base64) && printf '%s:%s\n' "$U" "$PW" | chpasswd && printf '%s\n' "$PW" > "/home/$U/SUDO-PASSWORD"; unset PW
  ```
  The user reads it with `ssh <admin>@<host> cat ~/SUDO-PASSWORD` (never read it yourself), saves it in their password manager, and deletes the file. For the rest of the run (phases 4–12), add the temporary grant `/etc/sudoers.d/90-vps-forge-temp` (`<admin> ALL=(ALL) NOPASSWD:ALL`) in the same deadman window. Remove it in phase 12. If the user declines the grant, do all remaining root work in the root session **before** disabling root login. For later agent sessions, the user can recreate the grant with a deadline: `systemd-run --on-active=2h rm -f /etc/sudoers.d/90-vps-forge-temp`.
- **NOPASSWD sudo (convenient).** `/etc/sudoers.d/10-<admin>` with `<admin> ALL=(ALL) NOPASSWD:ALL`. This is reasonable when the key is the only factor anyway (hardware or passphrase-protected key) and the box is agent-managed.

Always write sudoers files with `visudo -cf <file>` before moving them into place, using mode 440, inside a deadman window (step 2 above): `printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > /root/sudo.new && visudo -cf /root/sudo.new && install -m 440 /root/sudo.new /etc/sudoers.d/<name>; rm -f /root/sudo.new`. A broken sudoers file plus disabled root login means a trip to the console. A file *created* after `arm` can survive a rollback, so the `visudo -cf` check is what protects you here.

## The sshd drop-in trap (read this)

For most directives, **the first value sshd reads wins**. Debian and Ubuntu put `Include /etc/ssh/sshd_config.d/*.conf` at the top of `sshd_config`, and the files are read in lexical order. So:

- Name your file **`00-vps-forge.conf`**, not `99-...`. Cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`, and a `99-` file loses to it.
- If an image has directives **above** the `Include` line in `sshd_config`, those win over everything. Check with `grep -n -v '^\s*#' /etc/ssh/sshd_config | head`.
- `Match` blocks are the exception, because they must come last. Put them at the end of the file, or in a `zz-` file.
- Trust only the effective config: `sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods|allowgroups|allowusers|port|maxauthtries|x11forwarding|kexalgorithms|ciphers|macs|hostkey) '`

## Baseline sshd config

`assets/ssh/00-vps-forge.conf`:
```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowGroups sshusers
MaxAuthTries 5
MaxSessions 10
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
```
Notes:
- `AllowGroups sshusers` is easier to maintain than `AllowUsers`: adding a deploy user later is a single `usermod -aG sshusers`.
- `KbdInteractiveAuthentication no` matters. With `UsePAM yes` it is another way of entering a password.
- Keep `AllowTcpForwarding` at its default (yes) unless the user doesn't need SSH tunnels. Tunnels are the safe way to reach admin UIs and databases (`ssh -L 5432:127.0.0.1:5432 host`).
- Ubuntu 22.04 uses OpenSSH 8.9, which understands `KbdInteractiveAuthentication`. Older docs say `ChallengeResponseAuthentication`, which is the same setting.

Apply it with `sshd -t && systemctl reload ssh`. The service is named `ssh` on Debian and Ubuntu, not `sshd`.

## Hardened crypto (hardened+)

This is part of the SSH step at `hardened` (the default), not an optional extra: without it `ssh-audit` flags the OpenSSH defaults (NIST curves, SHA-1 MACs, RSA/ECDSA host keys), and `audit.sh` warns. Never paste a fixed algorithm list. sshd **refuses to start** if a name is unknown to its OpenSSH version. Build the list from what the server supports:

```bash
pick() { local have; have=$(ssh -Q "$1"); shift; local out=""; for a in "$@"; do grep -qx "$a" <<<"$have" && out+="${out:+,}$a"; done; echo "$out"; }
KEX=$(pick kex mlkem768x25519-sha256 sntrup761x25519-sha512 sntrup761x25519-sha512@openssh.com curve25519-sha256 curve25519-sha256@libssh.org)
CIPH=$(pick cipher chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com aes256-ctr aes192-ctr aes128-ctr)
MACS=$(pick mac hmac-sha2-512-etm@openssh.com hmac-sha2-256-etm@openssh.com umac-128-etm@openssh.com)
cat > /etc/ssh/sshd_config.d/01-vps-forge-crypto.conf <<EOF
# Generated by vps-forge for $(ssh -V 2>&1)
HostKey /etc/ssh/ssh_host_ed25519_key
KexAlgorithms $KEX
Ciphers $CIPH
MACs $MACS
EOF
# OpenSSH 9.8+ penalises addresses with failed logins on its own (PerSourcePenalties), ignoring
# fail2ban's ignoreip. Exempt the admin's IP, but only where sshd knows the option: an unknown
# keyword stops sshd from starting. $SSH_CLIENT is empty under sudo; client-ip isn't.
# An agent-session IP gets a `# agent session <date>` comment line above the entry.
ADMIN_IP=$(vps-forge-deadman client-ip) && [[ $ADMIN_IP =~ ^[0-9A-Fa-f:.]+$ ]] || { echo "no admin IP: stop"; exit 1; }
sshd -t -o "PerSourcePenaltyExemptList=$ADMIN_IP" 2>/dev/null &&
  echo "PerSourcePenaltyExemptList $ADMIN_IP" >> /etc/ssh/sshd_config.d/01-vps-forge-crypto.conf
sshd -t
```
- `mlkem768x25519-sha256` (post-quantum hybrid) exists from OpenSSH 9.9 onward (Debian 13). Older versions fall back to `sntrup761x25519` (8.5+) and then `curve25519`.
- `HostKey` lines **add up**: if the image has uncommented `HostKey` lines in the main `sshd_config`, RSA and ECDSA stay active. Comment those out, then check with `sshd -T | grep -i hostkey`.
- `HostKey` limited to ed25519 means clients that pinned the RSA or ECDSA host key will be asked to accept the ed25519 key once. Give the user the fingerprint to compare: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. The old key files stay on disk unused, so reverting is a one-line change. Deadman snapshots in `/var/lib/vps-forge/deadman/` hold root-only copies of `/etc/ssh`, host keys included: if you ever rotate or delete host keys, delete the older snapshots too.
- Leave `PubkeyAcceptedAlgorithms` at its default unless you know every client uses ed25519. Default OpenSSH already rejects `ssh-rsa` (SHA-1) signatures while accepting RSA keys with `rsa-sha2-*`.
- `DiffieHellman group-exchange` isn't in the list, so `/etc/ssh/moduli` doesn't matter.
- Check from the user's machine: `ssh-audit <host>` (`pipx run ssh-audit <host>`), or `external-check.sh --ssh-audit`. ssh-audit opens dozens of connections, so whitelist the user's IP in fail2ban first (firewall.md).

## Changing the port

This is noise reduction, not security; offer it only if the user wants quieter logs. First check the **provider firewall** (Hetzner, DigitalOcean, AWS security groups and so on, see firewall.md): if it allows only 22, open the new port there first, or every attempt just rolls back. Then, all in one deadman window:

1. `vps-forge-deadman arm 5`
2. ufw for the new port, admin rule first: `ufw prepend allow from <admin-ip> to any port <new> proto tcp comment 'admin'`, then `ufw limit <new>/tcp comment 'ssh'`.
3. Add `Port <new>` to `00-vps-forge.conf`. `Port` lines add up, so comment out any active `Port` in the main file: `sed -i -E 's/^[[:space:]]*Port[[:space:]]/#&/' /etc/ssh/sshd_config`. Check with `sshd -t && [ "$(sshd -T | grep -c '^port ')" = 1 ]`.
4. fail2ban: `sed -i -E 's/^port = .*/port = <new>/' /etc/fail2ban/jail.d/vps-forge.local` (sshd and recidive), then `systemctl reload fail2ban` (skip the reload while it is still masked: phase 5 starts it with the new port). Otherwise fail2ban keeps counting failures but bans them on the old port, which protects nothing. The deadman doesn't snapshot fail2ban: after a rollback, set the old port back by hand.
5. Apply:
   - **Socket-activated** (Ubuntu 22.10+, so 24.04; check with `systemctl is-enabled ssh.socket`): `sshd -t && systemctl daemon-reload && systemctl restart ssh.socket`. The port lives in the generated socket unit, not just sshd. Restarting the socket also restarts `ssh.service`, which runs `sshd -t` itself; a config error then leaves nothing listening until the deadman rolls back, so test first.
   - **Classic** (Debian): `sshd -t && systemctl restart ssh` (existing sessions survive; Debian's unit uses `KillMode=process`).
6. Delete the old port's rules exactly as `ufw status` shows them: `ufw delete limit 22/tcp` (or `ufw delete allow OpenSSH`) and `ufw delete allow from <admin-ip> to any port 22 proto tcp`. The live session survives, because ufw keeps established connections.
7. Test and disarm on the new port (`-p <new>`). If anything above broke, the new connection fails and the timer restores the old port and its rules.

Afterwards, `ss -Htlnp | grep -E 'sshd|systemd'` shows only the new port, and the user's `~/.ssh/config` gets the new `Port` (see "Verification and client config"). SELinux isn't present on Debian or Ubuntu, so no `semanage` step is needed.

## FIDO2 keys and TOTP (paranoid)

- **FIDO2 / hardware keys** (YubiKey and similar, OpenSSH 8.2+): the user runs `ssh-keygen -t ed25519-sk -O resident -O verify-required` locally, and the `sk-ssh-ed25519@openssh.com` public key goes into `authorized_keys`. That's all the server needs. This is the best upgrade per unit of effort.
- **TOTP as a second factor:** `apt-get install libpam-google-authenticator`. The user runs `google-authenticator` **as themselves, interactively**, because the secret must go to their phone, not through chat. Then:
  - `/etc/pam.d/sshd`: comment out `@include common-auth` (otherwise it also asks for the Unix password) and add, in this order:
    ```
    auth required pam_google_authenticator.so nullok
    auth required pam_permit.so
    ```
    The `pam_permit.so` line is not optional. For a user without `~/.google_authenticator`, `nullok` makes the module return "ignore", not "success". With `common-auth` gone, nothing else in the stack succeeds, so PAM refuses the login. Tested on Debian 12/13 and Ubuntu 24.04: without the line, every un-enrolled account is locked out.
  - `nullok` (with `pam_permit.so` after it) lets users who haven't enrolled yet (deploy and CI accounts) log in with their key only. Without it, every member of `sshusers` who hasn't run `google-authenticator` is locked out. Remove `nullok` only once every account is enrolled, or put service accounts in a `Match User` block with `AuthenticationMethods publickey`.
  - sshd: change the existing lines **in `00-vps-forge.conf` itself** to `KbdInteractiveAuthentication yes` and `AuthenticationMethods publickey,keyboard-interactive`. A new drop-in such as `10-2fa.conf` is silently ignored, because sshd keeps the first value it reads (see the drop-in trap above).
  - Do the PAM and sshd edits inside one deadman window: arm → edit both → `sshd -t` → `sshd -T | grep -Ei '^(kbdinteractiveauthentication|authenticationmethods) '` shows `yes` and `publickey,keyboard-interactive` → reload → the user logs in from a new terminal with `-o ControlPath=none` and gets the verification-code prompt → disarm. Scratch codes are printed once, and the user must store them offline.

## Cleaning up what the provider left

- Review `/root/.ssh/authorized_keys` and every `/home/*/.ssh/authorized_keys`. Ask about any key the user doesn't recognise. Once root login is off, root's file is unused; empty it if the user agrees.
- Default cloud users (`ubuntu`, `debian`, `admin`, `linuxuser`): once the new admin works, offer to lock (`usermod -L -e 1 <user>`) or remove them. Some providers' web consoles expect them, so ask first.
- Root password: `passwd -S root`. If you set one for console use, keep it. Otherwise `passwd -l root` locks it, which is harmless with key-only SSH and NOPASSWD sudo. Under password sudo, lock root only after the user has proven the saved password works (`ssh -t <admin>@<host> sudo -v`): otherwise a lost password leaves no way to root but the provider's rescue mode.
- `/etc/sudoers.d/90-cloud-init-users` often grants the cloud user NOPASSWD sudo. Remove it once that user is gone.

## Hand-off cleanup (phase 12)

Run these in this order. Under password sudo, removing the temporary grant takes away the agent's root, so it comes last:
1. Agent-session entries (SKILL.md rule 1), in one deadman window: `ufw delete allow from <agent-ip> to any port <port> proto tcp`; the `ignoreip` entry and its `# agent session` comment, then `systemctl reload fail2ban`; the agent IP in `PerSourcePenaltyExemptList` (`01-vps-forge-crypto.conf`), then `sshd -t && systemctl reload ssh`. The user's real IP belongs in all three places instead. Test and disarm.
2. Password sudo: `test ! -e /home/<admin>/SUDO-PASSWORD` (if it's still there, tell the user; don't read it) and `passwd -S <admin>` shows `P`. While the file exists, a stolen key is enough for root again.
3. `passwd -l root` only under the conditions in "Cleaning up what the provider left". Then write SERVER.md and make the final etckeeper commit.
4. Last step, in one call, because afterwards you have no root: `sudo sh -c 'rm -f /etc/sudoers.d/90-vps-forge-temp && etckeeper commit "vps-forge: remove temporary sudo grant"'`. Check that it is gone even after a rollback: the rollback deletes it only if it was created while the switch was armed. Then `ssh -o ControlPath=none -o BatchMode=yes -p <port> <admin>@<host> 'sudo -n -v'` must fail with `a password is required`. `audit.sh` flags a leftover grant.

## Verification and client config

```bash
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|allowgroups|port|maxauthtries) '
```
From the user's machine, after whitelisting their IP in fail2ban: `bash scripts/external-check.sh <host> --port <port> --user <admin> --root-test`. Expect `publickey` to be the only offered auth method, the admin login to work, and root to be refused. With 2FA configured correctly (`publickey,keyboard-interactive`), the unauthenticated probe still sees only `publickey`.

`external-check.sh` and your own tests pin one key, so they don't catch a user with many keys in their agent: every offered key counts against `MaxAuthTries`. The final report therefore always gives the user a `~/.ssh/config` block, not only after a port change:
```
Host myserver
  HostName <ip>
  User <admin>
  Port <port>
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```
