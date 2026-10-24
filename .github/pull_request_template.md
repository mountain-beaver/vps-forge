## What and why

<!-- What changes for someone running the skill, and why. -->

## Tested on

<!-- Distro + version (`/etc/os-release`), `ssh -V`, provider. "containers only" is fine for docs and audit checks. -->

## Checklist

- [ ] `make test` passes (and `make ci` if templates, `audit.sh` or `deadman.sh` changed)
- [ ] SSH, firewall, sudo and PAM guidance keeps the dead-man flow: arm → change → validate → test from a new session → disarm
- [ ] `audit.sh` stays read-only; `external-check.sh` stays bash 3.2 compatible
- [ ] Behaviour change → eval case added or adjusted in `evals/`
- [ ] `CHANGELOG.md` updated under *Unreleased*
