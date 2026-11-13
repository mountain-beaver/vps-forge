---
type: llm
focus: trace
weight: 1
---

The SSH crypto settings are built from what the server's OpenSSH supports (for example `ssh -Q kex`), not pasted as a fixed list, and the hardened level keeps a classic curve25519 fallback after the post-quantum algorithms.
