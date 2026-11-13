---
# The agent's own commands carry the agent-session marker.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*agent session'
---
