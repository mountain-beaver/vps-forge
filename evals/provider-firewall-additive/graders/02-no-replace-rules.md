---
# The rule set is never replaced in one call.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*replace-rules[^\n]*--rules-file'
match: not_contains
---
