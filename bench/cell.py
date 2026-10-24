#!/usr/bin/env python3
"""One benchmark cell, run inside its own network namespace:  pasta --config-net -- python3 cell.py ...

  cell.py bake --distro ubuntu-24.04 --scenario prod-docker-trap
      boot the cloud image, apply the scenario's starting state, power off: a frozen "server"
  cell.py run  --distro ubuntu-24.04 --scenario prod-docker-trap --arm skill --run-id X
      boot a copy of the baked server, let Claude work on it, then judge the result
  cell.py rejudge --run-id X [--into-result]
      judge a finished run's disk again (on a throw-away overlay; the run's own disk stays as it was)
  cell.py jailcheck --distro D --scenario S --run-id X [--skill-dir DIR]
      prepare the agent's private home and run a trivial command in the agent's sandbox instead of
      Claude: shows what the agent would see of the host

Both arms of a cell start from the same baked disk, so the only difference is the skill.
"""
import argparse
import base64
import calendar
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time
import traceback

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import judge  # noqa: E402
from vm import PORTS, PUBLIC_IP, SOURCES, SOURCES_REJUDGE, VM, default_user, seed_iso  # noqa: E402

BENCH = pathlib.Path(__file__).resolve().parent
CACHE = pathlib.Path(os.environ.get("VPS_FORGE_BENCH_CACHE", pathlib.Path.home() / ".cache" / "vps-forge-bench"))
IMAGES = {"debian-12": "debian-12.qcow2", "debian-13": "debian-13.qcow2", "ubuntu-22.04": "ubuntu-22.04.img",
          "ubuntu-24.04": "ubuntu-24.04.img", "ubuntu-26.04": "ubuntu-26.04.img"}
KEY = CACHE / "keys" / "bench"          # "the user's key"
ROOT_PASSWORD = "Tx7-provider-2026"     # what the provider emailed
MODEL = os.environ.get("BENCH_MODEL", "claude-opus-5-5")
AGENT_TIMEOUT = int(os.environ.get("BENCH_AGENT_TIMEOUT", 90 * 60))
TOOLS = "Bash Read Write Edit Glob Grep Skill WebFetch WebSearch TodoWrite"


def scenario(name, distro=None):
    """A scenario's config; "default" as the SSH user means the cloud image's default user."""
    cfg = json.loads((BENCH / "scenarios" / name / "scenario.json").read_text())
    if cfg.get("ssh_user") == "default":
        if not distro:
            raise SystemExit(f"{name} needs --distro to know its login")
        cfg["ssh_user"] = default_user(distro)
    cfg.setdefault("ssh_user", "root")
    return cfg


def setup_netns():
    for ip in [PUBLIC_IP, *SOURCES.values(), *SOURCES_REJUDGE.values()]:
        subprocess.run(["ip", "addr", "add", f"{ip}/32", "dev", "lo"], capture_output=True)


def ga_script(vm, path, timeout=1800):
    b64 = base64.b64encode(pathlib.Path(path).read_bytes()).decode()
    return vm.qga.run(f"echo {b64} | base64 -d > /root/.bench-setup.sh && bash /root/.bench-setup.sh; rc=$?; rm -f /root/.bench-setup.sh; exit $rc",
                      timeout=timeout)


def bake(distro, scen):
    cfg = scenario(scen, distro)
    d = CACHE / "baked" / f"{distro}--{scen}"
    if (d / "ok").exists():
        print(f"baked already: {d}")
        return
    if d.exists():
        shutil.rmtree(d)
    vm = VM(d, CACHE / "images" / IMAGES[distro], f"{distro}-{scen}", cfg["memory_mb"], 2, cfg.get("extra_disk_gb", 0))
    vm.create()
    iso = seed_iso(d, f"vps-{scen[:12]}", (KEY.with_suffix(".pub")).read_text().strip(), ROOT_PASSWORD, f"{distro}-{scen}",
                   style=cfg.get("cloud_init", "root"))
    vm.boot(iso)
    try:
        if not vm.wait_agent(900):
            raise SystemExit("guest agent never came up (see serial.log)")
        rc, out, err = vm.qga.run("cloud-init status --wait >/dev/null 2>&1; cloud-init status", timeout=1200)
        print("cloud-init:", out.strip())
        rc, out, err = ga_script(vm, BENCH / "scenarios" / scen / "setup.sh")
        (d / "setup.log").write_text(out + "\n--- stderr ---\n" + err)
        if rc != 0:
            raise SystemExit(f"setup failed rc={rc}: {err[-800:]}")
        vm.qga.run("apt-get clean; rm -f /root/.bash_history; sync", timeout=120)
    finally:
        vm.shutdown()
    (d / "ok").write_text(time.strftime("%FT%TZ"))
    print(f"baked {d}")


class PortWatcher(threading.Thread):
    """Publish any TCP port the guest starts listening on, like a VPS with a public IP would."""

    def __init__(self, vm):
        super().__init__(daemon=True)
        self.vm, self.stop, self.added = vm, threading.Event(), set(PORTS)

    def run(self):
        while not self.stop.wait(10):
            try:
                rc, out, _ = self.vm.qga.run("ss -Htln 2>/dev/null | awk '{print $4}'", timeout=20)
            except (OSError, ValueError):
                continue
            for addr in out.split():
                port = addr.rsplit(":", 1)[-1]
                if port.isdigit() and int(port) not in self.added and int(port) < 65536:
                    if not addr.startswith(("127.", "[::1]")):
                        self.vm.hostfwd_add(int(port))
                        self.added.add(int(port))


class Sink(http.server.BaseHTTPRequestHandler):
    """The user's ntfy server: records every alert (guest reaches it as 10.0.2.2:8099)."""
    log = None

    def _rec(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode(errors="replace") if n else ""
        with open(Sink.log, "a") as f:
            f.write(json.dumps({"t": time.time(), "method": self.command, "path": self.path,
                                "title": self.headers.get("Title") or self.headers.get("X-Title"), "body": body[:500]}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"id":"bench","event":"message"}')

    do_POST = do_PUT = do_GET = _rec

    def log_message(self, *a):
        pass


REAL_HOME = pathlib.Path(os.environ.get("BENCH_REAL_HOME", pathlib.Path.home()))
# Keys of ~/.claude.json that describe the user's other work or carry secrets: not given to the agent
PRIVATE_CONFIG_KEYS = {"mcpServers", "projects", "githubRepoPaths", "cachedArtifactRoster", "skillUsage", "pluginUsage",
                       "pluginPanes", "replBridgePlaceholders", "clientDataCacheSlots", "remoteControlSurfacesSeen",
                       "tipsHistory", "tipsHistoryByCommand", "pluginUsageLspGraceAppliedIds"}
# Environment the agent gets: an allowlist, so tokens in the user's shell environment stay out
AGENT_ENV = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TERM", "USER", "LOGNAME", "SHELL", "NIX_SSL_CERT_FILE",
             "SSL_CERT_FILE", "CLAUDE_CODE_OAUTH_TOKEN")
OAUTH_TOKEN_FILE = pathlib.Path(os.environ.get("BENCH_OAUTH_TOKEN_FILE", CACHE / "oauth-token"))


def real_dir(path):
    """Refuse a directory that is a symlink (or under one) before writing into it."""
    for q in [path, *path.parents]:
        if q.is_symlink():
            raise SystemExit(f"refusing to write through a symlink: {q}")
    return path


def private_login(dst):
    """A copy of the Claude login for one run: only the Claude.ai OAuth part, not the MCP tokens kept
    in the same file. The agent's jail mounts it read-only, and nothing is ever copied back: matrix.py
    refreshes the host's login before each pair so that a run never needs to refresh mid-run."""
    real = json.loads((REAL_HOME / ".claude" / ".credentials.json").read_text())
    mine = {k: real[k] for k in ("claudeAiOauth", "organizationUuid") if k in real}
    real_dir(dst.parent)
    tmp = dst.parent / f".credentials.{os.getpid()}.{time.time_ns()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(mine, f)
    os.replace(tmp, dst)


def fake_home(run_dir, cfg):
    home = run_dir / "home"
    (home / ".ssh").mkdir(parents=True, exist_ok=True)
    (home / ".claude").mkdir(exist_ok=True)
    for d in (home / ".ssh", home / ".claude"):
        real_dir(d)
    shutil.copy(KEY, home / ".ssh" / "id_ed25519")
    shutil.copy(KEY.with_suffix(".pub"), home / ".ssh" / "id_ed25519.pub")
    os.chmod(home / ".ssh" / "id_ed25519", 0o600)
    (home / ".ssh" / "config").write_text(f"Host vps\n  HostName {PUBLIC_IP}\n  User {cfg['ssh_user']}\n"
                                          "  IdentityFile ~/.ssh/id_ed25519\n  StrictHostKeyChecking accept-new\n")
    # A private ~/.claude per run: no user settings, hooks, plugins or memory leak in, and nothing
    # leaks out. The login is a read-only copy (see private_login), unless a long-lived token is set up.
    if not OAUTH_TOKEN_FILE.exists():
        private_login(home / ".claude" / ".credentials.json")
    conf = json.loads((REAL_HOME / ".claude.json").read_text())
    (home / ".claude.json").write_text(json.dumps({k: v for k, v in conf.items() if k not in PRIVATE_CONFIG_KEYS}))
    (run_dir / "work").mkdir(exist_ok=True)
    return home


def agent_env(home):
    env = {k: v for k, v in os.environ.items() if k in AGENT_ENV}
    env["HOME"] = str(home)
    if OAUTH_TOKEN_FILE.exists():  # `claude setup-token`: a long-lived token, nothing to refresh mid-run
        env["CLAUDE_CODE_OAUTH_TOKEN"] = OAUTH_TOKEN_FILE.read_text().strip()
    return env


def jail(run_dir, home, skill_dir):
    """The agent's sandbox (bubblewrap, nested in the pod): the host's /home, /tmp and /run are empty
    tmpfs, and only this run's private home and work dir come back read-write (the skill and the
    login copy read-only).
    The run directory itself (VM disk, QEMU monitor and guest-agent sockets, alert log, result) stays
    out of reach. A private PID namespace hides host processes, so /proc/<pid>/root cannot reach the
    real home either."""
    cmd = ["bwrap", "--dev-bind", "/", "/", "--tmpfs", "/home", "--tmpfs", "/tmp", "--tmpfs", "/run", "--tmpfs", "/dev/shm"]
    for keep in ("/run/current-system", "/run/booted-system", "/run/wrappers"):
        if os.path.exists(keep):
            cmd += ["--ro-bind", keep, keep]
    resolv = os.path.realpath("/etc/resolv.conf")  # pod.sh mounted the public resolver here
    if resolv.startswith("/run/"):
        cmd += ["--ro-bind", resolv, resolv]
    if str(REAL_HOME) != "/home" and not str(REAL_HOME).startswith("/home/"):
        cmd += ["--tmpfs", str(REAL_HOME)]
    cmd += ["--bind", str(home), str(home), "--bind", str(run_dir / "work"), str(run_dir / "work")]
    cred = home / ".claude" / ".credentials.json"
    if cred.is_file() and not cred.is_symlink():  # the login copy: readable, never writable by the agent
        cmd += ["--ro-bind", str(cred), str(cred)]
    if skill_dir:
        cmd += ["--ro-bind", str(skill_dir), str(skill_dir)]
    cmd += ["--unshare-pid", "--unshare-ipc", "--proc", "/proc", "--die-with-parent", "--chdir", str(run_dir / "work"), "--"]
    return cmd


def run_agent(run_dir, home, cfg, arm, skill_dir):
    env = agent_env(home)
    cmd = ["claude", "-p", "--model", MODEL, "--setting-sources", "project", "--strict-mcp-config",
           "--no-session-persistence", "--output-format", "stream-json", "--verbose", "--allowedTools", TOOLS]
    if arm == "skill":
        cmd += ["--plugin-dir", str(skill_dir)]
    prompt = (BENCH / "scenarios" / cfg["id"] / "prompt.md").read_text().replace("{ssh_user}", cfg["ssh_user"])
    t0 = time.time()
    with open(run_dir / "agent.jsonl", "w") as out, open(run_dir / "agent.stderr", "w") as err:
        try:
            p = subprocess.run(jail(run_dir, home, skill_dir if arm == "skill" else None) + cmd, input=prompt, text=True,
                               stdout=out, stderr=err, cwd=run_dir / "work", env=env, timeout=AGENT_TIMEOUT)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
    return rc, time.time() - t0


JAIL_PROBE = r"""
echo "HOME=$HOME  pwd=$(pwd)"
echo "--- ls -A $HOME"; ls -A "$HOME"
echo "--- ls -A $HOME/.claude"; ls -A "$HOME/.claude"
echo "--- credentials copy: $(python3 -I -c 'import json,os; d=json.load(open(os.path.expanduser("~/.claude/.credentials.json"))); o=d["claudeAiOauth"]; print("top-level keys", sorted(d), "| has access+refresh token:", all(isinstance(o.get(k), str) for k in ("accessToken", "refreshToken")))' 2>&1)"
c="$HOME/.claude/.credentials.json"
( : >> "$c" ) 2>/dev/null && echo "login copy WRITABLE" || echo "login copy: append refused (read-only)"
( echo '{}' > "$HOME/.claude/x.json" && mv -f "$HOME/.claude/x.json" "$c" ) 2>/dev/null && echo "login copy REPLACEABLE" || echo "login copy: replace refused"
for p in "$REAL/.ssh" "$REAL/projects" "$REAL/.claude/skills" "$REAL/.claude/.credentials.json" "$REAL/.cache/vps-forge-bench/keys"          "$RUN/host-only-canary" "/tmp/claude-$HOST_UID" /run/user /run/dbus; do
  printf '%-60s ' "$p"; ls -A "$p" >/dev/null 2>&1 && echo VISIBLE || echo hidden
done
echo "--- ls -A $REAL: $(ls -A "$REAL" | tr '\n' ' ')"
echo "--- processes visible: $(ls /proc | grep -c '^[0-9]')"
if [ -n "$SKILL" ]; then
  echo "--- skill dir: $(ls "$SKILL" | head -n 3 | tr '\n' ' ')"
  touch "$SKILL/x" 2>/dev/null && echo "skill dir WRITABLE" || echo "skill dir read-only"
fi
echo "--- tools: $(claude --version 2>&1 | head -n1) | $(ssh -V 2>&1) | $(python3 -V 2>&1)"
touch "$REAL/.jailcheck-canary" && echo "--- wrote $REAL/.jailcheck-canary inside the jail (lands in the jail's tmpfs)"
"""


def jailcheck(distro, scen, run_id, skill_dir):
    """Everything run() does for the agent, except that a shell prints what it sees instead of Claude."""
    cfg = scenario(scen, distro)
    run_dir = CACHE / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    home = fake_home(run_dir, cfg)
    (run_dir / "host-only-canary").write_text("the run directory outside home/ and work/ must stay hidden\n")
    env = {**agent_env(home), "REAL": str(REAL_HOME), "RUN": str(run_dir), "SKILL": str(skill_dir or ""),
           "HOST_UID": os.environ.get("POD_HOST_UID", "1000")}
    p = subprocess.run(jail(run_dir, home, skill_dir) + ["bash", "-c", JAIL_PROBE], text=True, capture_output=True,
                       cwd=run_dir / "work", env=env, timeout=60)
    print(p.stdout + p.stderr)


def agent_stats(path):
    st = {"skill_invoked": False, "tool_calls": 0, "rate": None, "result": None}
    for line in open(path, errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t = e.get("type")
        if t == "assistant":
            for c in (e.get("message", {}).get("content") or []):
                if c.get("type") == "tool_use":
                    st["tool_calls"] += 1
                    if c.get("name") == "Skill":
                        st["skill_invoked"] = True
        elif t == "rate_limit_event":
            st["rate"] = e.get("rate_limit_info")
        elif t == "result":
            st["result"] = {k: e.get(k) for k in ("subtype", "is_error", "duration_ms", "num_turns", "total_cost_usd", "usage")}
            st["final_text"] = (e.get("result") or "")[-6000:]
    return st


def run(distro, scen, arm, run_id, skill_dir):
    cfg = scenario(scen, distro)
    baked = CACHE / "baked" / f"{distro}--{scen}"
    if not (baked / "ok").exists():
        raise SystemExit(f"not baked: {baked}")
    run_dir = CACHE / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    meta = {"run_id": run_id, "distro": distro, "scenario": scen, "arm": arm, "model": MODEL,
            "skill_dir": str(skill_dir) if arm == "skill" else None, "started": time.strftime("%FT%TZ", time.gmtime())}
    vm = VM(run_dir, baked / "disk.qcow2", run_id, cfg["memory_mb"], 2, cfg.get("extra_disk_gb", 0))
    vm.create(extra_base=(baked / "extra.qcow2") if cfg.get("extra_disk_gb") else None)
    vm.boot(baked / "seed.iso")
    Sink.log = str(run_dir / "alerts.jsonl")
    pathlib.Path(Sink.log).touch()
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8099), Sink)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    watcher = PortWatcher(vm)
    try:
        if not vm.wait_agent(600) or not vm.wait_ssh(KEY, user=cfg["ssh_user"], timeout=600):
            raise SystemExit("VM did not come up")
        watcher.start()
        started = time.time()
        if arm != "noop":  # noop = judge the untouched server: the "before" picture
            home = fake_home(run_dir, cfg)
            rc, secs = run_agent(run_dir, home, cfg, arm, skill_dir)
            meta.update({"agent_rc": rc, "agent_seconds": round(secs)})
            meta["agent"] = agent_stats(run_dir / "agent.jsonl")
            time.sleep(30)  # let restarts settle, like a user who reconnects a bit later
        try:
            meta["judge"] = judge.judge(vm, cfg, KEY, run_dir / "alerts.jsonl", started, published=watcher.added)
        except Exception:  # no verdict: matrix.py judges the saved disk again (rejudge --into-result)
            meta["judge_error"] = traceback.format_exc()[-4000:]
    finally:
        watcher.stop.set()
        srv.shutdown()
        vm.shutdown(timeout=60)
        meta["finished"] = time.strftime("%FT%TZ", time.gmtime())
        (run_dir / "result.json").write_text(json.dumps(meta, indent=1, ensure_ascii=False))
    s = meta.get("judge", {}).get("score", {})
    if meta.get("judge_error"):
        print(f"{run_id}: JUDGE ERROR\n{meta['judge_error']}")
    print(f"{run_id}: score={s.get('score')} lockout={s.get('lockout')} passed={s.get('passed')}/{s.get('total')} "
          f"agent={meta.get('agent_seconds')}s rc={meta.get('agent_rc')}")


def epoch(iso):
    return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))


def rejudge(run_id, into_result=False):
    """Judge a finished run's disk again, as it was left (after the first judge and its reboot).
    The VM boots a throw-away overlay (runs/<id>/rj3/), so the run's own disk stays untouched and a
    rejudge can be repeated. Its probes come from SOURCES_REJUDGE: bans the first judge's probes
    left behind cannot skew it. Result: runs/<id>/rejudge.json, or, with into_result (the first
    judge crashed), the judge of result.json itself."""
    run_dir = CACHE / "runs" / run_id
    meta = json.loads((run_dir / "result.json").read_text())
    cfg = scenario(meta["scenario"], meta["distro"])
    baked = CACHE / "baked" / f"{meta['distro']}--{meta['scenario']}"
    ov = run_dir / "rj3"
    ov.mkdir(exist_ok=True)
    for f in ("disk.qcow2", "extra.qcow2", "qga.sock", "mon.sock", "qemu.pid"):
        if (ov / f).exists():
            os.remove(ov / f)
    vm = VM(ov, run_dir / "disk.qcow2", run_id, cfg["memory_mb"], 2, cfg.get("extra_disk_gb", 0))
    vm.create(extra_base=(run_dir / "extra.qcow2") if cfg.get("extra_disk_gb") else None)
    judge.use_sources(SOURCES_REJUDGE)
    # the run's own window: the VM booted after "started", the agent then worked agent_seconds
    started = epoch(meta["started"])
    worked = meta.get("agent_seconds") or 0
    old_alerts = (meta.get("judge") or {}).get("alerts") or {}
    vm.boot(baked / "seed.iso")
    Sink.log = str(ov / "alerts.jsonl")
    pathlib.Path(Sink.log).touch()
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8099), Sink)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    watcher = PortWatcher(vm)
    j = None
    try:
        if not vm.wait_agent(600):
            raise SystemExit("VM did not come up")
        watcher.start()
        time.sleep(60)
        try:
            j = judge.judge(vm, cfg, KEY, ov / "alerts.jsonl", started, published=watcher.added,
                            run_end=started + worked + 300, backup_bound=started + worked + 900,
                            alerts_during_run=old_alerts.get("received_during_run"))
        except Exception:
            j = {"judge_version": judge.JUDGE_VERSION, "judge_error": traceback.format_exc()[-4000:]}
    finally:
        watcher.stop.set()
        srv.shutdown()
        vm.shutdown(timeout=60)
    j["rejudged_at"] = time.strftime("%FT%TZ", time.gmtime())
    if into_result:
        if "judge_error" in j:
            meta["judge_error"] = j["judge_error"]
        else:
            meta["judge"] = j
            meta.pop("judge_error", None)
        tmp = run_dir / "result.json.tmp"
        tmp.write_text(json.dumps(meta, indent=1, ensure_ascii=False))
        os.replace(tmp, run_dir / "result.json")
    else:
        (run_dir / "rejudge.json").write_text(json.dumps(j, indent=1, ensure_ascii=False))
    if "judge_error" in j:
        print(f"{run_id}: rejudge JUDGE ERROR\n{j['judge_error']}")
        raise SystemExit(3)
    s = j["score"]
    print(f"{run_id}: rejudged score={s['score']} lockout={s['lockout']} ({s['lockout_reason']}) {s['passed']}/{s['total']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["bake", "run", "rejudge", "jailcheck"])
    ap.add_argument("--distro", choices=sorted(IMAGES))
    ap.add_argument("--scenario")
    ap.add_argument("--arm", choices=["baseline", "skill", "noop"])
    ap.add_argument("--run-id")
    ap.add_argument("--skill-dir")
    ap.add_argument("--into-result", action="store_true", help="rejudge: replace result.json's verdict")
    a = ap.parse_args()
    setup_netns()
    if a.mode == "rejudge":
        rejudge(a.run_id, a.into_result)
    elif a.mode == "jailcheck":
        jailcheck(a.distro, a.scenario, a.run_id, pathlib.Path(a.skill_dir) if a.skill_dir else None)
    elif a.mode == "bake":
        bake(a.distro, a.scenario)
    else:
        run(a.distro, a.scenario, a.arm, a.run_id, pathlib.Path(a.skill_dir) if a.skill_dir else None)


if __name__ == "__main__":
    main()
