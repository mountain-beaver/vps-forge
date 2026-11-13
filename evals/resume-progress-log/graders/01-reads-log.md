---
# The agent opens the copied progress.log (Read, or cat through Bash) instead of starting over.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*"name"\s*:\s*"(?:Read|Bash)"[^\n]*progress\.log'
---
