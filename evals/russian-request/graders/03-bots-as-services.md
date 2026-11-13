---
type: llm
focus: last_message
weight: 1
---

The plan for the bots (now or as a named later stage) runs them as unprivileged users or containers under systemd or Docker, keeps their secrets in owner-only files, and publishes no container port on all interfaces past ufw.
