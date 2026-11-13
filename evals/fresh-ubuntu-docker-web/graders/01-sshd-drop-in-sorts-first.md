---
# The sshd drop-in is named 00-*.conf (or another 0x- name) so it sorts before cloud-init's 50-cloud-init.conf. Deterministic: matches only the agent's own messages and tool inputs (assistant lines of the trace), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*sshd_config\.d/0[0-9]-[A-Za-z0-9_.-]*\.conf'
---
