---
# The sshd change is validated with sshd -t before ssh is reloaded or restarted. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*sshd -t[^\n]*systemctl (?:reload|restart) (?:ssh|sshd)\b'
---
