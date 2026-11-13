---
# The dead-man switch is armed before Port 2222 is written. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*deadman(?:\.sh)? arm[^\n]*Port 2222'
---
