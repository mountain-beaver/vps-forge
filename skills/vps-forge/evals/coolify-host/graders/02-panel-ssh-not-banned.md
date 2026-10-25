---
type: llm
focus: trace
weight: 1
---

The response exempts Coolify's own SSH connection to the host, which comes from Coolify's Docker network, from fail2ban and from any ufw rate limit on the SSH port, or explains that it must. The exemption is limited to that network; it does not exempt a whole private range such as 10.0.0.0/8.
