# Contributing

Thanks for helping make servers safer.

## Ground rules

- **Safety first.** Any change that touches SSH, firewall, sudo or PAM guidance must keep the dead-man switch flow intact: arm, change, validate, test from a new session, disarm.
- **Verify on real systems.** Say which distro and version you tested on (`/etc/os-release`, `ssh -V`). If something differs between releases, add it to `references/distro-notes.md` rather than assuming.
- **Explain why.** The skill teaches the agent the reasoning, not just commands. Short "why" sentences beat capitalised MUSTs.
- **Keep SKILL.md lean** (under 500 lines). Details belong in `references/`, deterministic work in `scripts/`, and copy-paste configs in `assets/`.

## Before opening a PR

```bash
make test                # shellcheck, JSON/YAML, frontmatter, versions, audit smoke test, deadman restore
make ci                  # + templates and audit.sh scenarios on all four distros, in containers
```
You need bash, shellcheck, python3 with PyYAML, jq, zip, and podman or docker for the container suites. The `claude` CLI is optional: with it, `make test` also runs `claude plugin validate --strict`.
Scripts must pass `shellcheck -S warning`. `audit.sh` must stay read-only. `external-check.sh` must stay compatible with macOS bash 3.2.

If you add a template, teach `tests/templates.sh` to validate it (and `fill()` in `tests/lib.sh` any new `<placeholder>`). If you add or change an `audit.sh` check, add a scenario to `tests/audit-scenarios.sh` that proves both its PASS and its FAIL.

If you change behaviour, add or adjust a case in `skills/vps-forge/evals/` (format: `claude plugin eval`).

`make eval` pins the judge model and uses `--threshold 0.85`: `llm` graders are noisy, so one missed grader in one run should not fail the suite. Fix a real regression, or replace a vague rubric with a deterministic `regex`, `tool_used`, `tool_order` or `file_exists` grader, instead of lowering the threshold.

## Good first contributions

- Provider notes (console location, firewall, snapshot quirks) for Hetzner, DigitalOcean, Vultr, OVH, Linode, Contabo, Oracle Cloud
- Additional `audit.sh` checks (with a clear PASS/WARN/FAIL rationale)
- Translations of the README, or fixes to the existing ones (`README.zh-CN.md`, `README.ja.md`, `README.ru.md`). A translation mirrors `README.md` exactly: the same links, images, commands, tables and `<details>` blocks, with in-page anchors pointing at the translated headings. Its first lines carry the language switcher and a `<!-- translation of README.md, source sha256: ... -->` comment with the first 12 hex digits of `sha256sum README.md` it was made from. `make test` fails on a structural difference and warns when the English README has moved on.
