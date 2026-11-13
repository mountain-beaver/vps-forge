---
# The final answer is written in the user's language (Cyrillic prose, not only commands).
type: regex
target: last_message
weight: 1
pattern: '[\u0400-\u04FF]{4,}[^\n]{0,40}[\u0400-\u04FF]{4,}'
---
