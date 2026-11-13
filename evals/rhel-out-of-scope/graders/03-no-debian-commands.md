---
# No apt or ufw commands in the agent's own output for a Rocky server.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:apt-get install|ufw (?:enable|default|allow|limit))'
match: not_contains
---
