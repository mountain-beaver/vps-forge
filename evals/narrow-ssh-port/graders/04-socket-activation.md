---
# On Ubuntu 24.04 the port change restarts ssh.socket (socket activation), not only ssh.service. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*systemctl[^\n]{0,80}restart ssh\.socket'
---
