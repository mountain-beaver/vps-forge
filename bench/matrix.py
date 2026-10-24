#!/usr/bin/env python3
"""Run the benchmark matrix: every distro x scenario, with and without the skill, in pairs.

  matrix.py bake                       bake every distro x scenario starting state (parallel)
  matrix.py run --skill-dir DIR        judge every untouched starting state, then run all cells --reps
                                       times (one full round before the next), the two arms of a cell
                                       back to back as a pair; stops launching new pairs when the
                                       7-day Claude usage has grown by --budget since the start
  matrix.py rejudge --tag v2           judge every saved run of a tag again with the current judge
                                       (VM time only, no Claude): runs/<id>/rejudge.json
A run whose judge crashed (result.json with judge_error) is not done: `run` judges its saved disk
again instead of running the agent again.
Results land in ~/.cache/vps-forge-bench/runs/<run-id>/result.json; report.py turns them into charts.
"""
import argparse
import concurrent.futures as cf
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time

BENCH = pathlib.Path(__file__).resolve().parent
CACHE = pathlib.Path(os.environ.get("VPS_FORGE_BENCH_CACHE", pathlib.Path.home() / ".cache" / "vps-forge-bench"))
DISTROS = ["ubuntu-24.04", "debian-13", "ubuntu-26.04", "debian-12", "ubuntu-22.04"]
SCENARIOS = ["prod-docker-trap", "fresh-docker-web", "ssh-port-socket", "fresh-sudo-user"]
ARMS = ["baseline", "skill"]
LOG = CACHE / "matrix.log"
OAUTH_TOKEN_FILE = pathlib.Path(os.environ.get("BENCH_OAUTH_TOKEN_FILE", CACHE / "oauth-token"))  # see cell.py
AGENT_TIMEOUT_H = int(os.environ.get("BENCH_AGENT_TIMEOUT", 90 * 60)) / 3600


def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def env():
    e = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}
    # kept next to the code, which is read-only inside pods (the cache is writable there)
    e["PATH"] = (BENCH / ".tools.path").read_text().strip()
    return e


def done(rid):
    """A run counts as done once it has a verdict, or once the agent itself errored (moved away)."""
    f = CACHE / "runs" / rid / "result.json"
    if not f.exists():
        return False
    try:
        r = json.loads(f.read_text())
    except ValueError:
        return False
    return bool((r.get("judge") or {}).get("score"))


def needs_rejudge(rid):
    """The agent finished but the judge crashed: judge the saved disk again, never rerun the agent."""
    f = CACHE / "runs" / rid / "result.json"
    if not f.exists() or done(rid):
        return False
    try:
        r = json.loads(f.read_text())
    except ValueError:
        return False
    return not ((r.get("agent") or {}).get("result") or {}).get("is_error") and (r.get("judge_error") or "judge" not in r)


def pod(args, logfile, timeout=None, rw=None):
    e = env()
    if rw:
        e["POD_RW"] = rw
    with open(logfile, "a") as f:
        return subprocess.run([str(BENCH / "pod.sh"), "python3", "-I", str(BENCH / "cell.py"), *args],
                              stdout=f, stderr=subprocess.STDOUT, env=e, timeout=timeout).returncode


REAL_LOGIN = pathlib.Path.home() / ".claude" / ".credentials.json"
REFRESH_DIR = CACHE / "login-refresh"  # host-only: pods cannot write the cache outside their run dir
login_lock = threading.Lock()
# The login flows one way, host -> pod. Each pod gets a read-only copy (cell.py private_login and
# jail); nothing a pod or an agent wrote is ever read back into the user's login or another pod.
# So no run may need to refresh mid-run: before each pair the host makes sure its own login lives
# longer than a run can take, refreshing it itself if needed.


def _oauth(path):
    """The Claude.ai OAuth block of a host-side login file if it is well-formed, else None."""
    try:
        d = json.loads(path.read_text())
        o = d["claudeAiOauth"]
        if all(isinstance(o.get(k), str) and o.get(k) for k in ("accessToken", "refreshToken")) and int(o.get("expiresAt", 0)) > 0:
            return o
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def login_hours_left():
    o = _oauth(REAL_LOGIN)
    return (int(o["expiresAt"]) / 1000 - time.time()) / 3600 if o else 0


def refresh_login(need_h):
    """Make the user's login outlive the next pair. Claude refreshes a token only when it is about to
    expire, so the refresh runs on a host-only copy marked as expired, with a one-word Haiku call;
    the new tokens go back into the user's login file only if they belong to the same account and
    organisation and expire later. Returns the hours left afterwards."""
    with login_lock:
        if login_hours_left() >= need_h:
            return login_hours_left()
        real = json.loads(REAL_LOGIN.read_text())
        REFRESH_DIR.mkdir(mode=0o700, exist_ok=True)
        home = REFRESH_DIR / f"h{os.getpid()}-{int(time.time())}"
        (home / ".claude").mkdir(mode=0o700, parents=True)
        stale = {"claudeAiOauth": {**real["claudeAiOauth"], "expiresAt": int(time.time() * 1000) - 60000},
                 "organizationUuid": real.get("organizationUuid")}
        cred = home / ".claude" / ".credentials.json"
        fd = os.open(cred, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(stale, f)
        conf = json.loads((pathlib.Path.home() / ".claude.json").read_text())
        (home / ".claude.json").write_text(json.dumps({k: conf[k] for k in ("hasCompletedOnboarding", "oauthAccount", "userID")
                                                      if k in conf}))
        subprocess.run(["claude", "-p", "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config",
                        "--no-session-persistence", "Reply with OK."], input="", text=True, capture_output=True,
                       env={**env(), "HOME": str(home)}, timeout=180, cwd=home)
        new = _oauth(cred)
        try:
            org_new = json.loads(cred.read_text()).get("organizationUuid")
        except (OSError, ValueError):
            org_new = None
        old = real["claudeAiOauth"]
        plausible = new and time.time() * 1000 < int(new["expiresAt"]) < time.time() * 1000 + 31 * 86400e3
        if plausible and int(new["expiresAt"]) > int(old["expiresAt"]) and org_new in (None, real.get("organizationUuid")) \
                and new.get("subscriptionType") == old.get("subscriptionType"):
            real["claudeAiOauth"] = new
            tmp = REAL_LOGIN.with_name(f".credentials.{os.getpid()}.{int(time.time() * 1e6)}.tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(real, f)
            os.replace(tmp, REAL_LOGIN)
            log(f"refreshed the login on the host: {login_hours_left():.1f} h left")
        else:
            log("login refresh on the host did not produce a newer token")
        shutil.rmtree(home, ignore_errors=True)  # host-only scratch copy made above
        return login_hours_left()


def bake_all(par, scenarios=None):
    jobs = [(d, s) for s in (scenarios or SCENARIOS) for d in DISTROS if not (CACHE / "baked" / f"{d}--{s}" / "ok").exists()]
    log(f"baking {len(jobs)} images")

    def one(j):
        d, s = j
        for attempt in range(2):
            rc = pod(["bake", "--distro", d, "--scenario", s], CACHE / "bake.log", timeout=3600, rw=str(CACHE / "baked"))
            if rc == 0:
                log(f"baked {d} {s}")
                return
            log(f"bake failed {d} {s} (attempt {attempt + 1})")
    with cf.ThreadPoolExecutor(par) as ex:
        list(ex.map(one, jobs))


def usage():
    """Current Claude subscription usage, read from a tiny Haiku call's rate-limit event."""
    r = subprocess.run(["claude", "-p", "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config",
                        "--no-session-persistence", "--output-format", "stream-json", "--verbose", "Reply with OK."],
                       input="", text=True, capture_output=True, env={**env(), "HOME": os.environ["HOME"]}, timeout=180)
    for line in r.stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "rate_limit_event":
            w = (e.get("rate_limit_info") or {}).get("unifiedWindows") or {}
            return {k: (w.get(k) or {}).get("utilization") for k in ("five_hour", "seven_day")}
    return None


def run_all(skill_dir, par, budget, tag, reps=1, only=None, usage_fn=None, pod_fn=None, login_refresh_fn=None):
    usage_fn, pod_fn, login_refresh_fn = usage_fn or usage, pod_fn or pod, login_refresh_fn or refresh_login
    u0 = usage_fn()
    if not u0 or u0.get("seven_day") is None:
        sys.exit("cannot read subscription usage")
    log(f"start usage: {u0}; budget +{budget:.0%} on the 7-day window")
    state = {"stop": False}
    lock = threading.Lock()
    cells = [(s, d) for s in SCENARIOS for d in DISTROS]
    if only:
        cells = [c for c in cells if f"{c[1]}/{c[0]}" in only]
    # a job is a list of runs started together: the untouched server alone, or the two arms of one
    # cell and repeat as a pair, so a budget stop never leaves half a pair
    jobs = [[(s, d, "noop", f"{tag}--{d}--{s}--before")] for s, d in cells]
    for k in range(1, reps + 1):
        for s, d in cells:
            jobs.append([(s, d, arm, f"{tag}--{d}--{s}--{arm}--r{k}") for arm in ARMS])
    jobs = [[r for r in j if not done(r[3])] for j in jobs]
    jobs = [j for j in jobs if j]

    def guard():
        u = usage_fn()
        with lock:
            if not u:
                return True
            log(f"usage now {u} (start {u0['seven_day']:.2f})")
            if u["seven_day"] is not None and u["seven_day"] - u0["seven_day"] >= budget:
                state["stop"] = True
                log("budget reached: no new pairs")
            while u and (u.get("five_hour") or 0) >= 0.92:
                log("5-hour window nearly full: waiting 10 min")
                time.sleep(600)
                u = usage_fn()
            return not state["stop"]

    def one(r):
        s, d, arm, rid = r
        if needs_rejudge(rid):
            log(f"rejudge {rid}: the judge crashed last time; judging the saved disk")
            rc = pod_fn(["rejudge", "--run-id", rid, "--into-result"], CACHE / "runs.log", timeout=2 * 3600)
            log(f"rejudged {rid} rc={rc} done={done(rid)}")
            return
        log(f"start {rid}")
        (CACHE / "runs" / rid).mkdir(parents=True, exist_ok=True)  # the pod can write only here
        rc = pod_fn(["run", "--distro", d, "--scenario", s, "--arm", arm, "--run-id", rid, "--skill-dir", str(skill_dir)],
                    CACHE / "runs.log", timeout=3 * 3600, rw=str(CACHE / "runs" / rid))
        res = CACHE / "runs" / rid / "result.json"
        r = json.loads(res.read_text()) if res.exists() else {}
        if ((r.get("agent") or {}).get("result") or {}).get("is_error"):
            # the agent never really ran (e.g. the Claude login expired): not a result, run it again later
            bad = CACHE / "invalid" / f"{rid}.{int(time.time())}"
            bad.parent.mkdir(exist_ok=True)
            os.replace(CACHE / "runs" / rid, bad)
            log(f"invalid {rid}: agent error ({(r['agent'].get('final_text') or '')[:120]!r}); moved to {bad}")
            return
        if r.get("judge_error"):
            log(f"judge crashed on {rid}; judging the saved disk again")
            rc = pod_fn(["rejudge", "--run-id", rid, "--into-result"], CACHE / "runs.log", timeout=2 * 3600)
            r = json.loads(res.read_text()) if res.exists() else {}
        sc = (r.get("judge") or {}).get("score", {})
        log(f"done {rid} rc={rc} score={sc.get('score')} lockout={sc.get('lockout')}")

    def pair(job):
        agent_runs = [r for r in job if r[2] != "noop" and not needs_rejudge(r[3])]
        if agent_runs:
            if state["stop"] or not guard():
                log(f"skipped pair {' + '.join(r[3] for r in job)}")
                job = [r for r in job if needs_rejudge(r[3])]  # judging a saved disk costs no Claude usage
                if not job:
                    return
            need = AGENT_TIMEOUT_H + 0.5  # the pods' copies are read-only: no refresh mid-run
            if not OAUTH_TOKEN_FILE.exists() and login_refresh_fn(need) < need:
                log(f"login lives only {login_hours_left():.1f} h, less than a run may take: skipped pair "
                    f"{' + '.join(r[3] for r in job)}")
                return
        with cf.ThreadPoolExecutor(len(job)) as ex:  # both arms at once: same time of day, same mirrors
            list(ex.map(one, job))

    # par counts VMs; a pair runs two
    with cf.ThreadPoolExecutor(max(1, par // 2)) as ex:
        list(ex.map(pair, jobs))
    log(f"matrix finished; final usage {usage_fn()}")


def rejudge_all(tag, par, only_ids=None):
    """Judge every saved run of a tag again (rejudge.json next to result.json). Resumable: runs that
    already have a verdict of the current judge version are skipped."""
    sys.path.insert(0, str(BENCH))
    from judge import JUDGE_VERSION
    ids = []
    for f in sorted((CACHE / "runs").glob(f"{tag}--*/result.json")):
        rid = f.parent.name
        if only_ids and rid not in only_ids:
            continue
        rj = f.parent / "rejudge.json"
        if rj.exists():
            try:
                j = json.loads(rj.read_text())
                if j.get("judge_version") == JUDGE_VERSION and j.get("score"):
                    continue
            except ValueError:
                pass
        ids.append(rid)
    log(f"rejudging {len(ids)} runs of {tag} with judge v{JUDGE_VERSION}, {par} at a time")

    def one(rid):
        rc = pod(["rejudge", "--run-id", rid], CACHE / "rejudge.log", timeout=2 * 3600, rw=str(CACHE / "runs" / rid))
        log(f"rejudged {rid} rc={rc}")
    with cf.ThreadPoolExecutor(par) as ex:
        list(ex.map(one, ids))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["bake", "run", "rejudge"])
    ap.add_argument("--skill-dir")
    ap.add_argument("--par", type=int, default=6)
    ap.add_argument("--budget", type=float, default=0.15)
    ap.add_argument("--tag", default="v2")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--only", nargs="*", help="cells as distro/scenario (run, bake) or run ids (rejudge)")
    ap.add_argument("--scenarios", nargs="*", help="bake only these scenarios")
    a = ap.parse_args()
    if a.mode == "bake":
        bake_all(min(a.par, 5), a.scenarios)
    elif a.mode == "rejudge":
        rejudge_all(a.tag, a.par, a.only)
    else:
        run_all(pathlib.Path(a.skill_dir), a.par, a.budget, a.tag, a.reps, a.only)


if __name__ == "__main__":
    main()
