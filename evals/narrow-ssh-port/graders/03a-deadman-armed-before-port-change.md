---
# The dead-man switch (or its rollback timer) is part of the port change, named before the new port: as the deadman.sh arm command, or in a plan when the agent asks for access first. Matches only assistant lines of the trace (the agent's messages and tool inputs), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:deadman(?:\.sh)? arm|dead-man switch|rollback timer)[^\n]*2222'
flags: i
---
