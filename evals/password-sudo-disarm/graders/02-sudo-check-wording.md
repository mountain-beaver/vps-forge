---
type: llm
focus: trace
weight: 1
---

The test of maria's sudo expects `sudo -n -v` to fail asking for a password (for example `a password is required`), treats a refusal such as `Sorry, user maria may not run sudo` as a broken policy, and checks that `passwd -S maria` shows a set password (P).
