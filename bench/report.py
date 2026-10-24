#!/usr/bin/env python3
"""Turn benchmark results into README charts (light + dark SVG) and a results table.

  report.py --tag v2 --out ../docs/bench [--rejudged]
Reads ~/.cache/vps-forge-bench/runs/<tag>--<distro>--<scenario>--before/result.json (the untouched
server) and <tag>--<distro>--<scenario>--<arm>--r<k>/result.json (repeated runs).
--rejudged takes each run's verdict from rejudge.json (matrix.py rejudge: the saved disk judged
again by the current judge) instead of result.json; a run without a current rejudge counts as broken.
Every run that was expected but has no verdict is counted (broken / missing), never dropped silently.
"""
import argparse
import html
import json
import os
import pathlib
import re
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from judge import JUDGE_VERSION  # noqa: E402

CACHE = pathlib.Path(os.environ.get("VPS_FORGE_BENCH_CACHE", pathlib.Path.home() / ".cache" / "vps-forge-bench"))
BENCH = pathlib.Path(__file__).resolve().parent
DISTROS = ["debian-12", "debian-13", "ubuntu-22.04", "ubuntu-24.04", "ubuntu-26.04"]
ALL_SCENARIOS = ["prod-docker-trap", "fresh-docker-web", "ssh-port-socket", "fresh-sudo-user"]
SCENARIOS = list(ALL_SCENARIOS)  # narrowed in main() to the scenarios that have data
SCEN_LABEL = {"prod-docker-trap": "Production Docker box", "fresh-docker-web": "Fresh VPS to production",
              "ssh-port-socket": "SSH port move + fail2ban", "fresh-sudo-user": "Fresh VPS, sudo user"}
ARMS = ("baseline", "skill")
POLICY_CHECK = "root cannot log in over SSH"
DISTRO_LABEL = {"debian-12": "Debian 12", "debian-13": "Debian 13", "ubuntu-22.04": "Ubuntu 22.04",
                "ubuntu-24.04": "Ubuntu 24.04", "ubuntu-26.04": "Ubuntu 26.04"}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

# Control (without the skill) is a deliberate neutral; the skill is categorical slot 1 (blue).
THEMES = {
    "light": {"bg": "#ffffff", "ink": "#1f2328", "ink2": "#59636e", "grid": "#d1d9e0", "base": "#8c959f",
              "skill": "#2a78d6", "before": "#d1d9e0", "crit": "#cf222e", "seq": ["#eaf2fb", "#c4dbf5", "#8db8ea", "#4f91de", "#2a78d6", "#1b5aa8"]},
    "dark": {"bg": "#0d1117", "ink": "#f0f6fc", "ink2": "#9198a1", "grid": "#30363d", "base": "#6e7681",
             "skill": "#3987e5", "before": "#30363d", "crit": "#f85149", "seq": ["#161b22", "#1b2f4a", "#1e4271", "#22569b", "#2a6cc4", "#3d86e6"]},
}


SHADE_STEPS = (50, 70, 80, 90, 100)  # grid cell shade: <50, 50s-60s, 70s, 80s, 90s, 100


def load(tag, rejudged=False, reps=None):
    """runs[(distro, scenario, arm)] = [result, ...] over repeats; before[(distro, scenario)] = result;
    broken[(distro, scenario, arm)] = [(run name, why), ...] for runs without a verdict, plus one
    ("rN", "missing") entry for every expected repeat that never produced a result."""
    runs, before, broken, seen = {}, {}, {}, {}
    for f in sorted((CACHE / "runs").glob(f"{tag}--*/result.json")):
        parts = f.parent.name.split("--")
        try:
            d = json.loads(f.read_text())
        except ValueError:
            d = {}
        why = None
        if rejudged:
            try:
                rj = json.loads((f.parent / "rejudge.json").read_text())
            except (OSError, ValueError):
                rj = {}
            if rj.get("judge_version") == JUDGE_VERSION and rj.get("score"):
                d = {**d, "judge": rj}
            else:
                why = "rejudge error" if rj.get("judge_error") else "not rejudged"
        if why is None and not (d.get("judge") or {}).get("score"):
            why = "judge error" if d.get("judge_error") else "no verdict"
        if why is None and ((d.get("agent") or {}).get("result") or {}).get("is_error"):
            why = "agent error"
        if len(parts) == 4 and parts[3] == "before":
            if why is None:
                before[(parts[1], parts[2])] = d
            else:
                broken.setdefault((parts[1], parts[2], "before"), []).append((f.parent.name, why))
        elif len(parts) == 5:
            key = (parts[1], parts[2], parts[3])
            seen.setdefault(key, set()).add(parts[4])
            if why is None:
                runs.setdefault(key, []).append(d)
            else:
                broken.setdefault(key, []).append((f.parent.name, why))
    reps = reps or max([int(r[1:]) for rs in seen.values() for r in rs if re.fullmatch(r"r\d+", r)] + [0])
    for s in {k[1] for k in seen}:
        for dd in DISTROS:
            for arm in ARMS:
                have = seen.get((dd, s, arm), set())
                for k in range(1, reps + 1):
                    if f"r{k}" not in have:
                        broken.setdefault((dd, s, arm), []).append((f"r{k}", "missing"))
    return runs, before, broken


def nbroken(broken, s, arm, d=None):
    return sum(len(v) for (dd, ss, aa), v in broken.items() if ss == s and aa == arm and d in (None, dd))


def self_bans(runs, s, arm, d=None):
    """(runs whose admin IP was banned while the agent worked, runs where that is known)."""
    xs = [(r["judge"].get("self_ban") or {}).get("banned") for dd in DISTROS if d in (None, dd) for r in runs.get((dd, s, arm), [])]
    known = [x for x in xs if x is not None]
    return sum(1 for x in known if x), len(known)


def score_without(r, check):
    """The run's score with one check left out (a lockout still scores 0)."""
    sc = r["judge"]["score"]
    c = {k: v for k, v in sc["checks"].items() if k != check}
    return 0 if sc["lockout"] else round(100 * sum(1 for v in c.values() if v) / len(c))


def mean(xs):
    return round(statistics.mean(xs)) if xs else None


def scores(runs, s, arm, d=None):
    return [r["judge"]["score"]["score"] for dd in DISTROS if d in (None, dd) for r in runs.get((dd, s, arm), [])]


def lockouts(runs, s, arm, d=None):
    return sum(1 for dd in DISTROS if d in (None, dd) for r in runs.get((dd, s, arm), []) if r["judge"]["score"]["lockout"])


class Svg:
    def __init__(self, w, h, t):
        self.w, self.h, self.t, self.parts = w, h, t, []

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=13, color="ink", anchor="start", weight=400):
        c = self.t.get(color, color)
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{c}" text-anchor="{anchor}" '
                 f'font-weight="{weight}">{html.escape(str(s))}</text>')

    def rect(self, x, y, w, h, fill, rx=0, stroke=None):
        f = self.t.get(fill, fill)
        st = f' stroke="{self.t.get(stroke, stroke)}" stroke-width="1.5"' if stroke else ""
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" height="{max(h, 0):.1f}" rx="{rx}" fill="{f}"{st}/>')

    def line(self, x1, y1, x2, y2, color="grid", width=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{self.t.get(color, color)}" stroke-width="{width}"{d}/>')

    def circle(self, x, y, r, fill, ring=True):
        st = f' stroke="{self.t["bg"]}" stroke-width="2"' if ring else ""
        self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{self.t.get(fill, fill)}"{st}/>')

    def render(self, title):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" '
                f'font-family="{FONT}" role="img" aria-label="{html.escape(title)}"><title>{html.escape(title)}</title>'
                f'<rect width="100%" height="100%" fill="{self.t["bg"]}"/>' + "".join(self.parts) + "</svg>")


def bar_top(svg, x, y, w, h, fill):
    """Bar with 4px rounded data-end, square at the baseline."""
    r = min(4, h / 2, w / 2)
    if h <= 0:
        return
    c = svg.t.get(fill, fill)
    svg.add(f'<path d="M{x:.1f},{y + h:.1f} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} H{x + w - r:.1f} '
            f'Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f} V{y + h:.1f} Z" fill="{c}"/>')


def hero(runs, before, theme):
    t = THEMES[theme]
    W, H = 880, 400
    svg = Svg(W, H, t)
    left, right, top, bottom = 48, 20, 70, 88
    ph = H - top - bottom
    svg.text(left, 28, "Security score of the finished server (independent judge, 0–100)", 16, weight=600)
    n = max([len(scores(runs, s, a)) for s in SCENARIOS for a in ("baseline", "skill")] + [0])
    svg.text(left, 50, f"Mean of up to {n} runs per bar: Debian 12/13 and Ubuntu 22.04/24.04/26.04, repeated · whisker: worst to best run · a lockout scores 0",
             12.5, "ink2")
    for v in (0, 25, 50, 75, 100):
        y = top + ph * (1 - v / 100)
        svg.line(left, y, W - right, y, "grid", 1)
        svg.text(left - 8, y + 4, v, 11, "ink2", "end")
    gw = (W - left - right) / len(SCENARIOS)
    bw = min(46, (gw - 30) / 3 - 4)
    for i, s in enumerate(SCENARIOS):
        gx = left + i * gw + gw / 2
        vals = {
            "before": [before[(d, s)]["judge"]["score"]["score"] for d in DISTROS if (d, s) in before],
            "baseline": scores(runs, s, "baseline"),
            "skill": scores(runs, s, "skill"),
        }
        for j, (arm, fill) in enumerate((("before", "before"), ("baseline", "base"), ("skill", "skill"))):
            x = gx + (j - 1.5) * (bw + 4) + 2
            m = mean(vals[arm])
            if m is None:
                svg.text(x + bw / 2, top + ph - 6, "n/a", 11, "ink2", "middle")
                continue
            h = ph * m / 100
            bar_top(svg, x, top + ph - h, bw, h, fill)
            lo, hi = min(vals[arm]), max(vals[arm])
            if hi > lo:  # spread across runs: a thin whisker from the worst to the best run
                y_lo, y_hi = top + ph * (1 - lo / 100), top + ph * (1 - hi / 100)
                svg.line(x + bw / 2, y_lo, x + bw / 2, y_hi, "ink2" if arm == "before" else "bg", 1.5)
                svg.line(x + bw / 2 - 5, y_lo, x + bw / 2 + 5, y_lo, "ink2" if arm == "before" else "bg", 1.5)
                svg.line(x + bw / 2 - 5, y_hi, x + bw / 2 + 5, y_hi, "ink2" if arm == "before" else "bg", 1.5)
            svg.text(x + bw / 2, top + ph - h - 8, m, 14 if arm == "skill" else 12.5,
                     "ink" if arm != "before" else "ink2", "middle", 700 if arm == "skill" else 500)
        svg.text(gx, top + ph + 20, SCEN_LABEL[s], 13, "ink", "middle", 600)
        # one line per scenario for both arms: per-bar labels are wider than the bars and collide
        locks = {arm: lockouts(runs, s, arm) for arm in ("baseline", "skill")}
        bans = {arm: self_bans(runs, s, arm) for arm in ("baseline", "skill")}
        y = top + ph + 34
        if any(locks.values()):
            svg.text(gx, y, f"locked out: {locks['baseline']}/{len(vals['baseline'])} without · "
                     f"{locks['skill']}/{len(vals['skill'])} with", 11, "crit", "middle", 600)
            y += 14
        if any(sb for sb, _ in bans.values()):
            svg.text(gx, y, f"self-banned: {bans['baseline'][0]}/{bans['baseline'][1]} without · "
                     f"{bans['skill'][0]}/{bans['skill'][1]} with", 11, "ink2", "middle", 600)
    lx = left
    for label, fill, stroke in (("Before (untouched server)", "before", None), ("Claude Opus 5.5 without the skill", "base", None),
                                ("Claude Opus 5.5 with vps-forge", "skill", None)):
        svg.rect(lx, H - 22, 12, 12, fill, 2, stroke)
        svg.text(lx + 18, H - 12, label, 12.5, "ink2")
        lx += 18 + len(label) * 7 + 26
    return svg.render("Security score with and without the vps-forge skill")


def check_rates(runs):
    rates = {}
    for (d, s, arm), rs in runs.items():
        for r in rs:
            for name, ok in r["judge"]["score"]["checks"].items():
                rates.setdefault(name, {}).setdefault(arm, []).append(1 if ok else 0)
    out, perfect = [], 0
    for name, by in rates.items():
        b, k = by.get("baseline", []), by.get("skill", [])
        if not b or not k:
            continue
        if sum(b) == len(b) and sum(k) == len(k):
            perfect += 1  # passed in every run of both arms: says nothing about the skill
            continue
        out.append((name, 100 * sum(b) / len(b), 100 * sum(k) / len(k), len(k)))
    out.sort(key=lambda x: (-(x[2] - x[1]), x[0]))
    return out, perfect


def checks_chart(runs, theme):
    t = THEMES[theme]
    rows, perfect = check_rates(runs)
    W = 880
    left, right, top, row = 330, 60, 96, 28
    H = top + row * len(rows) + 52
    svg = Svg(W, H, t)
    svg.text(24, 28, "Which checks pass, without vs with the skill", 16, weight=600)
    svg.text(24, 50, "Share of runs passing each independent check, all scenarios and distros", 12.5, "ink2")
    if perfect:
        svg.text(24, 68, f"Not shown: {perfect} checks that every run passed, with and without the skill", 12.5, "ink2")
    pw = W - left - right
    for v in (0, 50, 100):
        x = left + pw * v / 100
        svg.line(x, top - 10, x, top + row * len(rows) - 6, "grid", 1)
        svg.text(x, top - 16, f"{v}%", 11, "ink2", "middle")
    for i, (name, b, k, n) in enumerate(rows):
        y = top + i * row + row / 2
        svg.text(left - 14, y + 4, name, 12.5, "ink", "end")
        xb, xk = left + pw * b / 100, left + pw * k / 100
        svg.line(xb, y, xk, y, "ink2" if abs(k - b) > 0.5 else "grid", 2)
        svg.circle(xb, y, 5, "base")
        svg.circle(xk, y, 6, "skill")
        if abs(k - b) >= 1:
            svg.text(max(xb, xk) + 12, y + 4, f"{k - b:+.0f}", 11.5, "ink2", "start", 600)
    ly = H - 14
    svg.circle(24 + 6, ly - 4, 5, "base")
    svg.text(24 + 16, ly, "without the skill", 12.5, "ink2")
    svg.circle(24 + 150, ly - 4, 6, "skill")
    svg.text(24 + 162, ly, "with vps-forge", 12.5, "ink2")
    return svg.render("Pass rate per check without and with the skill")


def grid_chart(runs, before, broken, theme):
    t = THEMES[theme]
    cols = [(s, a) for s in SCENARIOS for a in ("baseline", "skill")]
    W = 880
    left, top, cw, ch = 130, 92, (880 - 130 - 20) / (2 * len(SCENARIOS)), 44
    H = top + ch * len(DISTROS) + 20
    svg = Svg(W, H, t)
    svg.text(24, 28, "Score per distro and scenario", 16, weight=600)
    svg.text(24, 50, "Mean of the repeated runs (Claude Opus 5.5, fresh VM) · shade steps at 70, 80, 90, 100 · red frame: a lockout"
             " · broken: a run without a verdict", 12, "ink2")
    for i, s in enumerate(SCENARIOS):
        svg.text(left + cw * (2 * i + 1), top - 26, SCEN_LABEL[s], 12.5, "ink", "middle", 600)
        svg.text(left + cw * (2 * i + 0.5), top - 8, "without", 11, "ink2", "middle")
        svg.text(left + cw * (2 * i + 1.5), top - 8, "with skill", 11, "ink2", "middle")
    for r, d in enumerate(DISTROS):
        y = top + r * ch
        svg.text(left - 12, y + ch / 2 + 4, DISTRO_LABEL[d], 12.5, "ink", "end")
        for c, (s, a) in enumerate(cols):
            x = left + c * cw
            xs = scores(runs, s, a, d)
            nb = nbroken(broken, s, a, d)
            if not xs:
                svg.rect(x + 2, y + 2, cw - 4, ch - 4, "bg", 3, "grid")
                svg.text(x + cw / 2, y + ch / 2 + 4, f"{nb} broken/missing" if nb else "–", 11 if nb else 12, "ink2", "middle")
                continue
            v = mean(xs)
            locks = lockouts(runs, s, a, d)
            # steps where the scores actually are; a linear 0-100 ramp painted 78 and 100 alike
            shade = t["seq"][sum(v >= b for b in SHADE_STEPS)]
            svg.rect(x + 2, y + 2, cw - 4, ch - 4, shade, 3, "crit" if locks else None)
            ink = "#ffffff" if v >= 80 or t["bg"] != "#ffffff" else t["ink"]
            svg.text(x + cw / 2, y + ch / 2 + 1, v, 14, ink, "middle", 700)
            sub = f"{locks}/{len(xs)} locked out" if locks else " · ".join(str(x_) for x_ in xs)
            if nb:
                sub += f" · {nb} broken"
            svg.text(x + cw / 2, y + ch / 2 + 15, sub, 10, ink if not locks or v >= 80 else "crit", "middle", 500)
    return svg.render("Score per distro and scenario")


def table(runs, before, broken):
    lines = ["| Scenario | Before | Without skill | With vps-forge | n (without / with) | Broken or missing (without / with) "
             "| Lockouts (without / with) | Self-bans (without / with) | Lynis (without / with) | Median time (without / with) |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    sens = ["| Scenario | Without skill | With vps-forge |", "|---|---:|---:|"]
    for s in SCENARIOS:
        def col(arm, key):
            return [key(r) for d in DISTROS for r in runs.get((d, s, arm), []) if key(r) is not None]
        sc = lambda r: r["judge"]["score"]["score"]
        lk = lambda r: 1 if r["judge"]["score"]["lockout"] else 0
        ly = lambda r: r["judge"].get("lynis")
        tm = lambda r: r.get("agent_seconds")
        bf = [before[(d, s)]["judge"]["score"]["score"] for d in DISTROS if (d, s) in before]
        b, k = col("baseline", sc), col("skill", sc)
        med = lambda xs: f"{round(statistics.median(xs) / 60)} min" if xs else "–"

        def sb(arm):
            n, known = self_bans(runs, s, arm)
            return f"{n}/{known}" if known else "–"
        lines.append(f"| {SCEN_LABEL[s]} | {mean(bf) if bf else '–'} | {mean(b) if b else '–'} | **{mean(k) if k else '–'}** | "
                     f"{len(b)} / {len(k)} | {nbroken(broken, s, 'baseline')} / {nbroken(broken, s, 'skill')} | "
                     f"{sum(col('baseline', lk))} / {sum(col('skill', lk))} | {sb('baseline')} / {sb('skill')} | "
                     f"{mean(col('baseline', ly)) or '–'} / {mean(col('skill', ly)) or '–'} | {med(col('baseline', tm))} / {med(col('skill', tm))} |")
        wo = lambda arm: mean(col(arm, lambda r: score_without(r, POLICY_CHECK))) if col(arm, sc) else "–"
        sens.append(f"| {SCEN_LABEL[s]} | {wo('baseline')} | {wo('skill')} |")
    return "\n".join(lines), "\n".join(sens)


def cell_table(runs, broken):
    """Per distro, scenario and arm: mean (n) and how many expected runs have no verdict."""
    head = "| Distro | " + " | ".join(f"{SCEN_LABEL[s]}: {'without' if a == 'baseline' else 'with'}" for s in SCENARIOS for a in ARMS) + " |"
    lines = [head, "|---|" + "---:|" * (2 * len(SCENARIOS))]
    for d in DISTROS:
        cells = []
        for s in SCENARIOS:
            for a in ARMS:
                xs = scores(runs, s, a, d)
                nb = nbroken(broken, s, a, d)
                cells.append((f"{mean(xs)} (n={len(xs)})" if xs else "–") + (f", {nb} broken/missing" if nb else ""))
        lines.append(f"| {DISTRO_LABEL[d]} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def provenance(runs, tag, rejudged):
    skills = sorted({pathlib.Path(r["skill_dir"]).name for rs in runs.values() for r in rs if r.get("skill_dir")})
    shas = sorted({m.group(0) for x in skills for m in [re.search(r"[0-9a-f]{7,40}$", x)] if m}) or skills
    jv = sorted({r["judge"].get("judge_version", 1) for rs in runs.values() for r in rs})
    models = sorted({r.get("model") for rs in runs.values() for r in rs if r.get("model")})
    how = "saved disks judged again with the current judge (rejudge.json)" if rejudged else "verdicts from the runs themselves"
    return (f"Tag `{tag}` · judge v{'/'.join(map(str, jv))} ({how}) · skill `{', '.join(shas) or '–'}` · "
            f"model `{', '.join(models) or '–'}`")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="v2")
    ap.add_argument("--out", default=str(BENCH.parent / "docs" / "bench"))
    ap.add_argument("--rejudged", action="store_true", help="verdicts from rejudge.json (current judge)")
    ap.add_argument("--reps", type=int, help="expected repeats per cell (default: the highest seen)")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    runs, before, broken = load(a.tag, a.rejudged, a.reps)
    SCENARIOS[:] = [s for s in ALL_SCENARIOS if any(k[1] == s for k in list(runs) + list(broken))]
    for theme in THEMES:
        sfx = "" if theme == "light" else "-dark"
        (out / f"hero{sfx}.svg").write_text(hero(runs, before, theme))
        (out / f"checks{sfx}.svg").write_text(checks_chart(runs, theme))
        (out / f"grid{sfx}.svg").write_text(grid_chart(runs, before, broken, theme))
    main_t, sens_t = table(runs, before, broken)
    md = (f"{provenance(runs, a.tag, a.rejudged)}\n\n{main_t}\n\n"
          f"Self-bans: runs in which the admin's own IP was banned (fail2ban or CrowdSec) while the agent worked. "
          f"Not part of the score; lockouts are the end state.\n\n"
          f"Sensitivity: mean score without the check \"{POLICY_CHECK}\" (the prompts say the user logs in as root today, "
          f"so key-only root is a defensible choice).\n\n{sens_t}\n\nPer distro (mean, number of runs, runs without a verdict):\n\n"
          f"{cell_table(runs, broken)}\n")
    (out / "results.md").write_text(md)
    slim = {f"{d}/{s}/{a_}": [{"score": r["judge"]["score"], "lynis": r["judge"].get("lynis"),
                                "self_ban": r["judge"].get("self_ban"), "backups": r["judge"].get("backups"),
                                "agent_seconds": r.get("agent_seconds"), "skill_invoked": (r.get("agent") or {}).get("skill_invoked"),
                                "turns": ((r.get("agent") or {}).get("result") or {}).get("num_turns")} for r in rs]
            for (d, s, a_), rs in sorted(runs.items())}
    slim["_meta"] = {"provenance": provenance(runs, a.tag, a.rejudged), "judge_version": JUDGE_VERSION, "rejudged": a.rejudged}
    slim["_broken"] = {f"{d}/{s}/{a_}": v for (d, s, a_), v in sorted(broken.items())}
    slim.update({f"{d}/{s}/before": {"score": r["judge"]["score"], "lynis": r["judge"].get("lynis")} for (d, s), r in sorted(before.items())})
    (out / "results.json").write_text(json.dumps(slim, indent=1))
    print(f"{sum(map(len, runs.values()))} runs, {len(before)} before-states, "
          f"{sum(map(len, broken.values()))} broken or missing -> {out}")
    print(md)


if __name__ == "__main__":
    main()
