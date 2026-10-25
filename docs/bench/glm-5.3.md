# Spot check: GLM-5.3 in ZCode

One run per arm on Debian 13, two scenarios, judge v3, the same pre-release skill (`8621325`) as the
Opus benchmark ([how to reproduce it from `v1.0.0`](../../bench/README.md#published-runs)). GLM-5.3 ran in the ZCode desktop app at High effort; a person started each session
with the scenario's prompt and approved ZCode's permission prompts. See [`bench/README.md`](../../bench/README.md#manual-runs).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="spot-glm-5.3-dark.svg">
  <img alt="GLM-5.3 spot check next to Claude Opus 5.5 on Debian 13. Production Docker box: Opus 80 without the skill and 100 with it, GLM-5.3 67 and 100. Fresh VPS to production: Opus 87 and 100, GLM-5.3 79 and 100." src="spot-glm-5.3.svg" width="880">
</picture>

## fresh-docker-web

| Check | Without the skill | With vps-forge |
|---|:---:|:---:|
| admin access with the user's key | pass | pass |
| admin access after reboot | pass | pass |
| no password logins offered | pass | pass |
| root cannot log in over SSH | **fail** | pass |
| ssh-audit: no failures | **fail** | pass |
| host firewall active | pass | pass |
| no forbidden port reachable | pass | pass |
| no forbidden port reachable after reboot | pass | pass |
| no unexpected open ports | pass | pass |
| brute-force protection active | pass | pass |
| a brute-force source gets banned | **fail** | pass |
| automatic security updates | pass | pass |
| app still serves | pass | pass |
| app serves after reboot | pass | pass |
| backup scheduled | pass | pass |
| backup ran during setup | pass | pass |
| app data restorable from backup | pass | pass |
| test alert delivered | pass | pass |
| SSH login triggers an alert | **fail** | pass |
| **Score** | **79 (15/19)** | **100 (19/19)** |
| Admin locked out | no | no |
| Admin's own IP banned while the agent worked | no | no |
| Lynis | 70 | 73 |

## prod-docker-trap

| Check | Without the skill | With vps-forge |
|---|:---:|:---:|
| admin access with the user's key | pass | pass |
| admin access after reboot | pass | pass |
| no password logins offered | pass | pass |
| root cannot log in over SSH | **fail** | pass |
| ssh-audit: no failures | **fail** | pass |
| host firewall active | pass | pass |
| no forbidden port reachable | pass | pass |
| no forbidden port reachable after reboot | pass | pass |
| no unexpected open ports | pass | pass |
| brute-force protection active | **fail** | pass |
| a brute-force source gets banned | **fail** | pass |
| automatic security updates | **fail** | pass |
| app still serves | pass | pass |
| app serves after reboot | pass | pass |
| app containers still running | pass | pass |
| **Score** | **67 (10/15)** | **100 (15/15)** |
| Admin locked out | no | no |
| Admin's own IP banned while the agent worked | no | no |
| Lynis | 68 | 73 |

Time and cost are not reported: a person was in the loop, and the runs used a ZCode subscription.
