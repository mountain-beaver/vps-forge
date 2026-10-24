---
type: llm
focus: trace
weight: 1
---

The SSH port change runs inside a rollback safety net (the dead-man switch or an equivalent timer) and is tested from a new connection on port 2222 before the safety net is disarmed.
