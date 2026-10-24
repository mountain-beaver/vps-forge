# Security policy

This project gives AI agents instructions and scripts that run as root on servers. A flaw can lock people out of their machines or leave them less secure than they think.

**Please report privately** via GitHub's "Report a vulnerability" (Security tab → Advisories), not in public issues. Examples of what to report:

- a flow that can lose SSH access despite the dead-man switch
- a check in `audit.sh` that reports PASS for an insecure state
- a template that weakens a default
- any way secrets could leak (into chat, argv, logs or world-readable files)

You'll get a response within a few days. Fixes are released as a patch version with credit, unless you prefer otherwise.
