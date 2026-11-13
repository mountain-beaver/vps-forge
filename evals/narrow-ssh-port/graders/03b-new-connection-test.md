---
# The new port is proven from a new connection: ssh -o ControlPath=none, or a fresh login / second terminal named in the plan. Matches only assistant lines of the trace.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:ControlPath=none|(?:new|fresh|second|separate) (?:SSH )?(?:connection|login|session|terminal))'
flags: i
---
