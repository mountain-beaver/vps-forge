---
tags: [vps-forge]
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

My Hetzner dedicated box runs Proxmox VE 8 (Debian 12 underneath) with a few VMs. Lock it down with your usual VPS hardening: ufw, fail2ban, sysctl, SSH. I'm root over SSH at 203.0.113.70.
