---
# fail2ban uses the systemd backend, or CrowdSec replaces it. A regex over the whole trace, because a long run's trace is cut short for an LLM judge and the jail is written early. Matches only assistant lines (the agent's messages and tool inputs, such as a written jail file), not the skill text it read.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*(?:backend\s*=\s*systemd|crowdsec)'
flags: i
---
