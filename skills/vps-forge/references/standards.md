# Where the defaults differ from CIS, Lynis and ssh-audit

Auditors and users run these tools against a finished server, and a few of their findings are deliberate choices. Explain them instead of "fixing" them. Change a setting only when the user has to comply with that standard, and then record the choice and its cost in SERVER.md.

## The deliberate differences

| Setting | vps-forge | What the tool suggests | Why vps-forge differs |
|---|---|---|---|
| `MaxAuthTries` | 5 | Lynis (SSH-7408): 3. CIS benchmarks also ask for a low limit. | Every key the user's agent offers counts as a try, so with 3 a user with several keys fails before the right one is tried. Passwords are off, so the extra tries give an attacker nothing, and fail2ban bans repeated failures. If every client uses `IdentitiesOnly yes`, 3 is fine. |
| `MaxSessions` | 10 | Lynis: 2 | One multiplexed connection (ControlMaster) carries several sessions: the agent's own commands, `scp`, `rsync`. 2 breaks that. |
| `AllowTcpForwarding` | yes (OpenSSH default) | Lynis: no. CIS Ubuntu 24.04 lists `DisableForwarding yes` at Level 2 (as published in Tenable's audit files). | SSH tunnels are how the user reaches admin UIs and databases that stay bound to `127.0.0.1` (ssh.md). Turning tunnels off pushes people to open those ports instead. Set `DisableForwarding yes` when nobody uses tunnels and no tool needs them. |
| `Banner` | none | Compliance profiles ask for a login banner (the DISA STIG for Ubuntu 24.04 checks `Banner /etc/issue.net`). | A banner is a legal notice, not a control: it stops no one. Add `Banner /etc/issue.net` when an organisation's policy requires one. |
| `KexAlgorithms` | post-quantum hybrids first, then `curve25519-sha256` (hardened) | ssh-audit 3.9+: warns about curve25519 (`does not provide protection against post-quantum attacks`) | Clients without the hybrids (OpenSSH before 8.5, Kamal and other Ruby net-ssh tools, many libraries) still connect. Every current OpenSSH client picks a hybrid first. The paranoid level drops curve25519 (ssh.md "Hardened crypto"). |
| Host key | ed25519 only | ssh-audit: `(rec) +rsa-sha2-256`, `+rsa-sha2-512` "key algorithm to append" | An informational recommendation, not a warning: it appears because the RSA host key is no longer offered. |
| `Port` | 22 unless the user wants another | Lynis: not 22 | A moved port cuts log noise, not risk (ssh.md "Changing the port"). The skill offers it and doesn't push it. |
| `LogLevel` | INFO (default) | Lynis: VERBOSE | At INFO, sshd already logs the key fingerprint of every accepted login (`Accepted publickey … SHA256:…`), which is what the skill reads. VERBOSE is harmless if an auditor insists. |

## Where they agree

Root login, password and keyboard-interactive login off, `AllowGroups`, `X11Forwarding no`, `AllowAgentForwarding no`, `PermitUserEnvironment no`, `ClientAliveInterval 300` with `ClientAliveCountMax 2`, `LoginGraceTime` at most 120 s, no SHA-1 MACs and no NIST curves: these match Lynis's SSH-7408 expectations, and ssh-audit reports no failures.

## Using the tools

- **Lynis:** `lynis audit system`, then read the suggestions with the table above in mind. The hardening index is a rough number; a suggestion listed here isn't a defect.
- **ssh-audit:** see ssh.md "Hardened crypto". Exit code 2 with only the curve25519 warning is the expected hardened result; `external-check.sh --ssh-audit` reports it as a pass.
- **CIS:** benchmark texts and numbering change between versions, and the skill doesn't reproduce them. For a compliance audit, take the exact benchmark version the auditor uses and go through its SSH section item by item, with this table as the list of known differences.
