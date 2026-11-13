---
# PermitRootLogin no appears only after the test of the new admin login in the agent's script.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:ControlPath=none|new (?:terminal|connection))[^\n]*PermitRootLogin no'
---
