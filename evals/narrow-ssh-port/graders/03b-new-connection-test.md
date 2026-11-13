---
# The new port is tested from a new, unmultiplexed connection (ssh -o ControlPath=none -p 2222). Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:ControlPath=none[^\n]*-p 2222|-p 2222[^\n]*ControlPath=none)'
---
