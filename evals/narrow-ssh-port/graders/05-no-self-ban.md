---
# The admin's IP goes on fail2ban's ignore list (ignoreip), as config or in the plan. Matches only assistant lines of the trace.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:(?:ignoreip|ignore ?list)[^\n]*fail2ban|fail2ban[^\n]*(?:ignoreip|ignore ?list))'
flags: i
---
