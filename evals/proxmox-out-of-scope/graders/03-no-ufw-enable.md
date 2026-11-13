---
# No ufw enable or routed deny in the agent's own commands.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*ufw (?:--force )?enable'
match: not_contains
---
