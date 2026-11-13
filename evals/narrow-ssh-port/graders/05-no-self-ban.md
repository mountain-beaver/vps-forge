---
# The admin's IP is written to fail2ban's ignoreip before fail2ban is started or restarted. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*ignoreip[^\n]*systemctl (?:enable --now|start|restart|unmask) fail2ban'
---
