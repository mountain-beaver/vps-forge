---
# On Ubuntu 24.04 the port change has to deal with ssh.socket (socket activation), as a command or in the plan. Matches only assistant lines of the trace.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*ssh\.socket'
flags: i
---
