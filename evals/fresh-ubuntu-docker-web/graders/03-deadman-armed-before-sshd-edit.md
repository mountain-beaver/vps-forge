---
# In the script the agent writes, the dead-man switch is armed before the sshd drop-in is written. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*deadman(?:\.sh)? arm[^\n]*sshd_config\.d/'
---
