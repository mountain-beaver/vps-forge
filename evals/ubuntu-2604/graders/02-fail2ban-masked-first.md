---
# fail2ban is masked before the install that would start it.
type: regex
target: trace
weight: 1
pattern: '"(?:type|role)"\s*:\s*"assistant"[^\n]*systemctl mask fail2ban[^\n]*apt-get[^\n]*install[^\n]*fail2ban'
---
