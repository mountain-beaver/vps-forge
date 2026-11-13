---
# apt runs with DEBIAN_FRONTEND=noninteractive, so the script cannot hang on a prompt. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*DEBIAN_FRONTEND=noninteractive'
---
