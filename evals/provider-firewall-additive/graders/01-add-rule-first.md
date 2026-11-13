---
# hcloud firewall add-rule for 2222 comes before the sshd Port change in the agent's output.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*hcloud firewall add-rule[^\n]*2222[^\n]*Port 2222'
---
