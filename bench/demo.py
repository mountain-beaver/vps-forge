#!/usr/bin/env python3
"""Record and render the dead-man switch demo: a bad sshd change, a failed login, an automatic undo.

  demo.py record --out demo.json          # runs the scenario for real (podman, localhost/u24sd)
  demo.py svg demo.json --out d.svg [--theme light|dark]
  demo.py frames demo.json --dir frames/  # still SVGs at 10 fps, for ffmpeg (MP4/GIF for posts)

Recording boots a throwaway Ubuntu 24.04 container with systemd as PID 1, installs deadman.sh,
creates an "admin" user with a key and a "vps" host alias, then runs each step and keeps its real
output and timing. Nothing is staged: the login really fails and the timer really rolls back.
The only edit at render time is the wait, which is shortened and labelled as such.
"""
import argparse
import json
import pathlib
import subprocess
import sys
import time
from xml.sax.saxutils import escape

REPO = pathlib.Path(__file__).resolve().parent.parent
IMAGE = "localhost/u24sd"
MINUTES = 1  # the demo arms for one minute; the default is five

SSH = ("ssh -i /root/k -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
       "-o LogLevel=ERROR -o ConnectTimeout=5")
# Each step: where it runs, the exact command (shown verbatim), and a dimmed note after its output.
# "server" runs inside the admin's existing SSH session (a ControlMaster connection, like the agent's),
# "laptop" runs a fresh login from outside it.
STEPS = [
    ("server", f"sudo vps-forge-deadman arm {MINUTES}", f"one minute for the demo; the default is 5"),
    ("server", "echo 'AllowUsers deploy' | sudo tee /etc/ssh/sshd_config.d/50-users.conf", "the mistake: admin isn't on the list"),
    ("server", "sudo sshd -t && sudo systemctl reload ssh && echo 'sshd -t: OK'", "valid config, so validation alone can't catch it"),
    ("laptop", "ssh -o ControlPath=none admin@vps true", "a NEW connection is refused, so nobody disarms"),
    ("wait", "", ""),
    ("server", "sudo vps-forge-deadman status", ""),
    ("laptop", "ssh -o ControlPath=none admin@vps 'echo logged in as $USER'", "the bad change is gone, and so is the lockout"),
]


def podman(*a, check=True, **kw):
    return subprocess.run(["podman", *a], check=check, text=True, capture_output=True, **kw)


def record(out):
    c = f"vf-demo-{int(time.time())}"
    podman("run", "-d", "--name", c, "--hostname", "vps", "--systemd=always", "--cap-add", "NET_ADMIN",
           "--cap-add", "SYS_PTRACE", "-v", f"{REPO}:/src:ro", IMAGE)
    x = lambda cmd: podman("exec", c, "bash", "-c", cmd, check=False)
    try:
        for _ in range(60):
            if x("systemctl is-system-running").stdout.strip() in ("running", "degraded"):
                break
            time.sleep(1)
        setup = ("apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends sudo openssh-client >/dev/null 2>&1"
                 " && install -m 755 /src/skills/vps-forge/scripts/deadman.sh /usr/local/sbin/vps-forge-deadman"
                 " && useradd -m -s /bin/bash admin && usermod -p '*' admin"
                 " && ssh-keygen -q -t ed25519 -N '' -f /root/k"
                 " && install -d -m 700 -o admin -g admin ~admin/.ssh && install -m 600 -o admin -g admin /root/k.pub ~admin/.ssh/authorized_keys"
                 " && echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin"
                 " && echo '127.0.0.1 vps' >> /etc/hosts && systemctl enable --now ssh >/dev/null 2>&1"
                 f" && {SSH} admin@vps true")
        r = x(setup)
        if r.returncode:
            sys.exit(f"setup failed: {r.stdout}{r.stderr}")
        # the admin's long-lived session, as an agent keeps it: commands below reuse it
        x(f"{SSH} -fN -o ControlMaster=yes -o ControlPath=/root/cm -o ControlPersist=10m admin@vps")
        events, t0 = [], time.monotonic()
        for where, shown, note in STEPS:
            if where == "wait":
                start = time.monotonic()
                while time.monotonic() - start < MINUTES * 60 + 90:
                    if "ROLLED BACK" in x("vps-forge-deadman status").stdout and \
                            x("systemctl is-active --quiet vps-forge-deadman.service").returncode:
                        break
                    time.sleep(2)
                events.append({"t": time.monotonic() - t0, "wait": round(time.monotonic() - start)})
                continue
            q = "'" + shown.replace("'", "'\\''") + "'"
            cmd = f"{SSH} -o ControlPath=/root/cm admin@vps {q}" if where == "server" else \
                shown.replace("ssh ", SSH + " ", 1)
            start = time.monotonic() - t0
            r = x(cmd)
            events.append({"t": start, "where": where, "cmd": shown, "out": (r.stdout + r.stderr).rstrip("\n"),
                           "rc": r.returncode, "note": note})
        out.write_text(json.dumps({"image": IMAGE, "minutes": MINUTES, "events": events}, indent=1))
        print(json.dumps(events, indent=1))
    finally:
        podman("rm", "-f", "-t", "0", c, check=False)


THEMES = {
    "light": dict(bg="#F3F5F7", frame="#D3DAE1", ink="#14202B", dim="#5E6E7E", you="#1F5FAD", ok="#1E7F5A", bad="#C2412D", bar="#E6EBF0"),
    "dark": dict(bg="#0E161E", frame="#26333F", ink="#E4EBF1", dim="#8796A5", you="#6CA8F0", ok="#3FB683", bad="#E5654F", bar="#16212C"),
}
COLS, FS, LH, PAD, TOP = 96, 13, 19, 24, 50
CW = FS * 0.6
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
PROMPT = {"server": "admin@vps:~$ ", "laptop": "you@laptop:~$ "}
TYPE_CPS, AFTER_CMD, AFTER_OUT, WAIT_S, HOLD = 38, 0.35, 0.25, 3.0, 7.0


def wrap(text, width):
    out = []
    for line in text.split("\n"):
        while len(line) > width:
            cut = line.rfind(" ", 0, width)
            cut = cut if cut > width // 2 else width
            out.append(line[:cut])
            line = "  " + line[cut:].lstrip()
        out.append(line)
    return out


def timeline(events):
    """Rows with start times: (kind, text, start, extra). kind: cmd, out, note, wait."""
    rows, t = [], 0.6
    for e in events:
        if "wait" in e:
            rows.append(("wait", f"timer running: {e['wait']} s, shortened here to {WAIT_S:.0f} s", t, WAIT_S))
            t += WAIT_S + 0.4
            continue
        p = PROMPT[e["where"]]
        dur = len(e["cmd"]) / TYPE_CPS
        rows.append(("cmd", p + e["cmd"], t, dur))
        t += dur + AFTER_CMD
        for ln in wrap(e["out"], COLS):
            if ln:
                kind = "bad" if e["rc"] else "ok" if ("ROLLED BACK" in ln or "logged in" in ln) else "out"
                rows.append((kind, ln, t, 0))
        t += AFTER_OUT
        if e["note"]:
            rows.append(("note", "# " + e["note"], t, 0))
            t += AFTER_OUT
        t += 0.3
    return rows, t + HOLD


def colour(kind, th):
    return {"cmd": th["ink"], "out": th["ink"], "bad": th["bad"], "ok": th["ok"], "note": th["dim"], "wait": th["dim"]}[kind]


def frame_svg(rows, total, th, title, at=None):
    """The whole demo as one SVG. at=None: CSS-animated loop; at=seconds: a still of that moment."""
    width = PAD * 2 + int(COLS * CW) + 8
    height = TOP + len(rows) * LH + 46
    css, body = [], []
    for i, (kind, text, start, dur) in enumerate(rows):
        y = TOP + (i + 1) * LH - 4
        col = colour(kind, th)
        if kind == "cmd":
            p = PROMPT["server"] if text.startswith(PROMPT["server"]) else PROMPT["laptop"]
            cmd = text[len(p):]
            pcol = th["you"] if p == PROMPT["laptop"] else th["ok"]
            if at is not None:
                if at < start:
                    continue
                n = len(cmd) if dur == 0 else min(len(cmd), int(len(cmd) * (at - start) / dur))
                cmd = cmd[:n]
            body.append(f'<text class="r{i}" x="{PAD}" y="{y}" xml:space="preserve"><tspan fill="{pcol}">{escape(p)}</tspan>'
                        f'<tspan fill="{col}">{escape(cmd)}</tspan></text>')
            if at is None:
                a, b = 100 * start / total, 100 * (start + dur) / total
                px = len(p) * CW
                css.append(f"@keyframes r{i}{{0%,{a:.2f}%{{opacity:0;clip-path:inset(0 100% 0 0)}}{a + 0.01:.2f}%{{opacity:1;clip-path:inset(0 calc(100% - {px + PAD:.0f}px) 0 0)}}"
                           f"{b:.2f}%,97%{{opacity:1;clip-path:inset(0 0 0 0)}}100%{{opacity:0}}}}"
                           f".r{i}{{animation:r{i} {total:.1f}s steps({max(1, len(cmd))}) infinite}}")
            continue
        if kind == "wait":
            bw = int(COLS * CW * 0.42)
            frac = 1.0 if at is None else max(0.0, min(1.0, (at - start) / dur))
            if at is not None and at < start:
                continue
            body.append(f'<g class="r{i}"><text x="{PAD}" y="{y}" fill="{col}">… {escape(text)}</text>'
                        f'<rect x="{PAD + int(50 * CW)}" y="{y - 10}" width="{bw}" height="8" rx="4" fill="{th["bar"]}"/>'
                        f'<rect class="w{i}" x="{PAD + int(50 * CW)}" y="{y - 10}" width="{int(bw * frac)}" height="8" rx="4" fill="{th["dim"]}"/></g>')
            if at is None:
                a, b = 100 * start / total, 100 * (start + dur) / total
                css.append(f"@keyframes r{i}{{0%,{a:.2f}%{{opacity:0}}{a + 0.3:.2f}%,97%{{opacity:1}}100%{{opacity:0}}}}.r{i}{{animation:r{i} {total:.1f}s linear infinite}}"
                           f"@keyframes w{i}{{0%,{a:.2f}%{{width:0}}{b:.2f}%,100%{{width:{bw}px}}}}.w{i}{{animation:w{i} {total:.1f}s linear infinite}}")
            continue
        if at is not None and at < start:
            continue
        body.append(f'<text class="r{i}" x="{PAD}" y="{y}" fill="{col}" xml:space="preserve">{escape(text)}</text>')
        if at is None:
            a = 100 * start / total
            css.append(f"@keyframes r{i}{{0%,{a:.2f}%{{opacity:0}}{a + 0.3:.2f}%,97%{{opacity:1}}100%{{opacity:0}}}}.r{i}{{animation:r{i} {total:.1f}s linear infinite}}")
    style = (f"text{{font-family:{MONO};font-size:{FS}px;white-space:pre}}" + "".join(css) +
             "@media (prefers-reduced-motion: reduce){*{animation:none!important;opacity:1!important;clip-path:none!important}}")
    dots = "".join(f'<circle cx="{PAD + 8 + 18 * i}" cy="20" r="5.5" fill="{th["frame"]}"/>' for i in range(3))
    head = f'<text x="{width / 2:.0f}" y="25" fill="{th["dim"]}" text-anchor="middle" style="font-size:12px">{escape(title)}</text>'
    foot = (f'<text x="{PAD}" y="{height - 16}" fill="{th["dim"]}" style="font-size:11.5px">Real output: Ubuntu 24.04 container with systemd, '
            f'recorded by bench/demo.py. Only the wait is shortened.</text>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
            f'aria-label="{escape(title)}"><title>{escape(title)}</title><style>{style if at is None else f"text{{font-family:{MONO};font-size:{FS}px;white-space:pre}}"}</style>'
            f'<rect x="1" y="1" width="{width - 2}" height="{height - 2}" rx="12" fill="{th["bg"]}" stroke="{th["frame"]}"/>'
            f'<path d="M1 38 H{width - 1}" stroke="{th["frame"]}"/>{dots}{head}{"".join(body)}{foot}</svg>')


TITLE = "A bad sshd change, a refused login, and the automatic undo"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--out", type=pathlib.Path, required=True)
    v = sub.add_parser("svg")
    v.add_argument("rec", type=pathlib.Path)
    v.add_argument("--out", type=pathlib.Path, required=True)
    v.add_argument("--theme", choices=THEMES, default="light")
    f = sub.add_parser("frames")
    f.add_argument("rec", type=pathlib.Path)
    f.add_argument("--dir", type=pathlib.Path, required=True)
    f.add_argument("--fps", type=int, default=12)
    f.add_argument("--theme", choices=THEMES, default="dark")
    a = ap.parse_args()
    if a.cmd == "record":
        record(a.out)
        return
    rows, total = timeline(json.loads(a.rec.read_text())["events"])
    if a.cmd == "svg":
        a.out.write_text(frame_svg(rows, total, THEMES[a.theme], TITLE))
        print(f"{a.out} ({a.out.stat().st_size // 1024} KB, {total:.0f} s loop)")
    else:
        a.dir.mkdir(parents=True, exist_ok=True)
        end = total - HOLD + 4  # the last frame holds in the video player, no need to loop
        n = int(end * a.fps)
        for k in range(n + 1):
            (a.dir / f"f{k:04d}.svg").write_text(frame_svg(rows, total, THEMES[a.theme], TITLE, at=k / a.fps))
        print(f"{n + 1} frames in {a.dir}")


if __name__ == "__main__":
    main()
