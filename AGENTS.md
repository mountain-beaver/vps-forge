# vps-forge

An [Agent Skill](https://agentskills.io) for hardening Debian/Ubuntu servers. The repository root is also a Claude Code plugin (`.claude-plugin/`), and `npx skills add` / `gh skill install` find the skill in `skills/`, so the same tree installs everywhere. The skill lives in `skills/vps-forge/`:
- `SKILL.md`: workflow and safety rules. Keep it under 500 lines.
- `references/`: one file per phase, loaded on demand.
- `scripts/`: bash that runs as root on servers.
- `assets/`: config templates.
- `evals/`: behaviour evals in `claude plugin eval` format.

## Commands

- `make test`: lint, manifests, version check, audit smoke test, deadman round trip. No sudo needed.
- `make directory`: builds `dist/directory`, the plugin folder that Anthropic's directory reads from the `directory` branch (only `.claude-plugin/plugin.json`, the icon, `skills/vps-forge` without evals, LICENSE and `.github/directory/README.md`). `.github/workflows/directory.yml` commits it to that branch on every release tag.
- `make ci`: every CI suite in podman/docker containers on Debian 12/13 and Ubuntu 22.04/24.04/26.04.
  - Narrow it with `DISTRO=debian:13 make templates` or `make audit`.
- `make lint`: the static checks only (no containers, no network, no root).
- Tools: bash, shellcheck, python3 with PyYAML, jq, zip, and podman or docker for the container suites.
- `make eval`: runs the behaviour evals. It spends tokens, so run it only when asked.

## Invariants (CI enforces most of them)

- `audit.sh` is read-only. `tests/audit-scenarios.sh` checksums the filesystem around it.
- `external-check.sh` runs on users' Macs, so it must stay compatible with bash 3.2: no `mapfile`, no `${var,,}`, no associative arrays.
- Every script passes `shellcheck -S warning`.
- Versions must agree in three places: `.claude-plugin/plugin.json`, the first released `## x.y.z` heading in `CHANGELOG.md`, and `VERSION=` in `audit.sh`.
  - Release: bump all three, then tag `vX.Y.Z`. The release workflow refuses a tag that doesn't match.
- Templates use `<placeholder>` syntax.
  - A new placeholder needs a value in `fill()` in `tests/lib.sh`, otherwise `tests/templates.sh` fails.
  - The `write_files` in `assets/cloud-init.yaml` must stay consistent with the standalone templates. The test compares the effective sshd values.
- Any SSH, firewall, sudo or PAM guidance keeps the dead-man flow: arm → change → validate → test from a new session → disarm.

## Tests that modify /etc

`tests/templates.sh` and `tests/audit-scenarios.sh` rewrite `/etc` and refuse to run outside a container. Always start them through `tests/in-container.sh`, never on the host.

## Skill text

- Keep the skill agent-neutral: say "the agent", not a product name, and do not rely on one tool's built-ins.
- `name` must stay `vps-forge` (it equals the directory name); `description` stays under 1024 characters and leads with what the skill does and when to use it.
