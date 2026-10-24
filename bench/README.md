# Benchmark: Claude with and without vps-forge

This directory holds the harness behind the charts in the main README. It gives Claude Opus the same
server task twice, once with only its own knowledge and once with the vps-forge skill. Real VMs are
used for every run, and an independent judge scores the result.

## What a run is

1. **A baked server.** Each scenario's `setup.sh` runs once per distro on the official cloud image
   (Debian 12/13, Ubuntu 22.04/24.04/26.04). The VM is then powered off. Both arms of a cell boot
   copy-on-write clones of the same disk, so the skill is the only difference between them.
2. **The agent.** Headless `claude -p --model claude-opus-5-5`, given the scenario's `prompt.md`:
   - The prompt says the user is offline, so the agent cannot ask questions.
   - It gets `ssh vps` access with the user's key: as root, or in `fresh-sudo-user` as the image's
     default user with passwordless sudo.
   - It has a fresh, empty `~/.claude`: no user settings, memory, hooks, plugins or MCP servers.
   - The skill arm adds exactly one thing, `--plugin-dir` pointing at a frozen copy of the skill.
   - It runs in a sandbox (bubblewrap inside the cell's pod). `/home`, `/tmp` and `/run` are empty
     there, and only the run's private home and work directory come back read-write, plus the frozen
     skill read-only in the skill arm. The user's real home, the VM's sockets and disk, the alert log
     and the result are out of reach, and a private PID namespace hides host processes.
     `cell.py jailcheck` shows what the agent can see without starting Claude.
   - Its Claude login is a read-only copy of the OAuth part of the user's login file. The login
     only flows from the host to the pods; nothing an agent wrote is ever read back. Before each
     pair, `matrix.py` makes sure the host's login outlives a run, refreshing it on the host if
     needed, so no run has to refresh mid-run. A long-lived token from `claude setup-token`, saved
     in `~/.cache/vps-forge-bench/oauth-token`, replaces the copy and needs no refresh at all.
3. **The judge** (`judge.py`). It never uses the skill's own scripts. Each check is something an outsider
   can observe, or a fact read through the QEMU guest agent, which plays the provider's web console:
   - logins with the user's key, and whether that login can become root: `sudo -n`, or password sudo
     with a password the admin can read in their own files. Membership in the sudo group alone is not
     enough;
   - the auth methods sshd offers, whether root can log in, and `ssh-audit`;
   - which ports answer from outside, and whether the app still serves. The ports checked are a fixed
     list, plus every port the guest published during the run, plus every TCP port the guest listens
     on at judging time;
   - whether a brute-force source really gets banned while a bystander still gets in;
   - whether backups ran and can be restored. A file of the app's data is pulled out of the backup
     and must match the live copy byte for byte. The backup can be a plain or rsync copy, a tar
     archive (any compression), or a restic or borg repository. For a repository, the password is
     looked up where a scheduled job would find it. "Scheduled" means an active timer or cron entry
     whose job, or the script it runs, is a backup of the app;
   - whether the alerts reached the user's ntfy topic, including one about a fresh SSH login from an
     address the run never used;
   - automatic updates: unattended-upgrades installed, with both `Update-Package-Lists` and
     `Unattended-Upgrade` on and the timer enabled;
   - all of the above again after a provider-style reboot;
   - Lynis as a third-party hardening index (reported, not scored);
   - **self-bans** (reported, not scored): whether the admin's own IP was banned while the agent worked,
     according to fail2ban's database and log or CrowdSec's alerts. A ban that expires before the end
     shows up only here. Lockouts are the end state.
4. **The score** is the share of passed checks. **A lockout scores 0**: there is no admin login with
   the user's key, either after setup or after the reboot. In real life that server is gone until
   someone opens the provider console.
5. **No verdict is not a result.** A crashed judge leaves `judge_error` in `result.json`, and
   `matrix.py` judges the saved disk again rather than running the agent again. The report lists
   every expected run without a verdict as broken or missing.

## Scenarios

| Scenario | What the user asks | The traps |
|---|---|---|
| `prod-docker-trap` | "Somebody said my shop server is insecure, audit and fix it, keep the shop online" | Docker publishes Postgres and Adminer past ufw; root and password logins come from two different drop-ins; an unknown old key in root's `authorized_keys`; updates off |
| `fresh-docker-web` | "New VPS, make it production: Docker app, secure, daily backups to the extra volume, alerts to my phone" | `50-cloud-init.conf` password login; Docker ports bypass ufw; backups must really run and restore; alerts must arrive |
| `ssh-port-socket` | "Admin user `deploy`, SSH on 2222, no passwords or root, fail2ban, auto-updates; must survive a reboot" | socket-activated sshd on Ubuntu 24.04+; first-match-wins sshd config; fail2ban that watches the wrong unit/port and never counts anything |
| `fresh-sudo-user` | Same as `fresh-docker-web`, on a stock cloud image: root login disabled by cloud-init, the user's key on `debian`/`ubuntu` with passwordless sudo | everything goes through sudo; banning the admin's own IP has no root fallback |

Routine tasks that Claude solves anyway were left out on purpose.

## Fairness notes

- **Same model, prompt, VM image and tools in both arms.** Every result keeps its run's transcript
  (`agent.jsonl`).
- **No questions to the user.** Both arms are told the user is offline.
- **Separate source addresses.** The judge's probes that are meant to fail (wrong users, root, listing
  auth methods, ssh-audit, the brute force) come from their own addresses, never from the admin's IP.
  The first version of the judge got this wrong: after the reboot, a strict fail2ban banned the
  admin's IP for the judge's own failed probes, and those runs counted as lockouts. That version's
  results were thrown away and every cell was run again.
- **Repeats.** Each distro × scenario × arm cell runs three times. The charts show the mean, and the
  ticks show every individual run.
- **Untouched servers** are judged the same way ("Before").
- **Pairs.** Both arms of a cell and repeat start together, and the budget guard only stops between
  pairs.
- **Rejudging.** `matrix.py rejudge --tag T` judges every saved disk again with the current judge. It
  boots a throw-away overlay, so the run's own disk stays as it was. Its probes come from a second
  set of source addresses, so bans left by the first judge cannot skew it. The window for backups
  and self-bans is the original run's.

## Published runs

- **v3** (24 Oct 2026, the charts in the main README): 4 scenarios × 5 distros × 2 arms × 3 repeats =
  120 runs, judge v3. The benchmarked skill is a pre-release commit (`8621325` in
  `results.md`); every later change is listed in the CHANGELOG, and 1.1.0 changed behaviour.
  Every run has a verdict. One baseline run (`debian-12/fresh-sudo-user` r1) failed to start because
  its Claude login was revoked mid-matrix. Its agent never touched the server, so it was run again
  five hours later on its own, apart from its pair.
- **v2** (23 Oct 2026): an earlier, pre-release version of the skill, 3 scenarios, 90 runs. Its
  numbers, which the README quotes for comparison, are judge v3 verdicts on the saved v2 disks
  (`report.py --tag v2 --rejudged`).
- **v1** was thrown away: see "Separate source addresses" above.

## Running it

The harness needs Linux with KVM, `pasta` (passt), QEMU, xorriso, ssh-audit and socat. It needs no
root: each cell gets its own network namespace. Then:

```bash
python3 bench/matrix.py bake                       # once: build every starting server
python3 bench/matrix.py run --skill-dir <frozen skill> --reps 3 --budget 0.15
python3 bench/report.py --tag v3 --out docs/bench  # charts + results table
python3 bench/matrix.py rejudge --tag v2           # optional: judge saved runs again (no Claude)
python3 bench/report.py --tag v2 --rejudged --out /tmp/v2  # report from the rejudged verdicts
```

`--budget` stops launching new runs once your 7-day Claude usage has grown by that share. Results,
VM disks and transcripts go to `~/.cache/vps-forge-bench/runs/`.
