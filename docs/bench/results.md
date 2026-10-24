Tag `v3` · judge v3 (verdicts from the runs themselves) · skill `8621325` · model `claude-opus-5-5`

| Scenario | Before | Without skill | With vps-forge | n (without / with) | Broken or missing (without / with) | Lockouts (without / with) | Self-bans (without / with) | Lynis (without / with) | Median time (without / with) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Production Docker box | 40 | 79 | **99** | 15 / 15 | 0 / 0 | 0 / 0 | 0/15 / 0/15 | 69 / 71 | 3 min / 6 min |
| Fresh VPS to production | 32 | 88 | **100** | 15 / 15 | 0 / 0 | 0 / 0 | 1/15 / 0/15 | 72 / 72 | 5 min / 8 min |
| SSH port move + fail2ban | 25 | 88 | **100** | 15 / 15 | 0 / 0 | 0 / 0 | 4/15 / 0/15 | 64 / 72 | 3 min / 5 min |
| Fresh VPS, sudo user | 42 | 92 | **100** | 15 / 15 | 0 / 0 | 0 / 0 | 2/15 / 0/15 | 73 / 72 | 6 min / 8 min |

Self-bans: runs in which the admin's own IP was banned (fail2ban or CrowdSec) while the agent worked. Not part of the score; lockouts are the end state.

Sensitivity: mean score without the check "root cannot log in over SSH" (the prompts say the user logs in as root today, so key-only root is a defensible choice).

| Scenario | Without skill | With vps-forge |
|---|---:|---:|
| Production Docker box | 85 | 100 |
| Fresh VPS to production | 93 | 100 |
| SSH port move + fail2ban | 87 | 100 |
| Fresh VPS, sudo user | 92 | 100 |

Per distro (mean, number of runs, runs without a verdict):

| Distro | Production Docker box: without | Production Docker box: with | Fresh VPS to production: without | Fresh VPS to production: with | SSH port move + fail2ban: without | SSH port move + fail2ban: with | Fresh VPS, sudo user: without | Fresh VPS, sudo user: with |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Debian 12 | 78 (n=3) | 100 (n=3) | 91 (n=3) | 100 (n=3) | 88 (n=3) | 100 (n=3) | 93 (n=3) | 100 (n=3) |
| Debian 13 | 80 (n=3) | 100 (n=3) | 87 (n=3) | 100 (n=3) | 88 (n=3) | 100 (n=3) | 91 (n=3) | 100 (n=3) |
| Ubuntu 22.04 | 78 (n=3) | 95 (n=3) | 84 (n=3) | 100 (n=3) | 88 (n=3) | 100 (n=3) | 95 (n=3) | 100 (n=3) |
| Ubuntu 24.04 | 78 (n=3) | 98 (n=3) | 91 (n=3) | 100 (n=3) | 88 (n=3) | 100 (n=3) | 91 (n=3) | 100 (n=3) |
| Ubuntu 26.04 | 82 (n=3) | 100 (n=3) | 86 (n=3) | 100 (n=3) | 90 (n=3) | 100 (n=3) | 91 (n=3) | 100 (n=3) |
