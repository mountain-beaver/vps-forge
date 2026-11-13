---
type: llm
focus: trace
weight: 1
---

Because maria's sudo asks for a password, the response does not rely on `sudo -n vps-forge-deadman disarm` over her connection: the dead-man switch is disarmed from the existing root session (or by the user typing the sudo password), after a new connection as maria has been proven.
