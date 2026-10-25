---
type: llm
focus: trace
weight: 1
---

The response keeps root login by key for Coolify (PermitRootLogin prohibit-password, not "no") and makes sure AllowGroups or AllowUsers still lets root in, for example by adding root to the sshusers group.
