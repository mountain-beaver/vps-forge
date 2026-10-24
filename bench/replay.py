#!/usr/bin/env python3
"""Render a real run as an animated terminal SVG: the prompt, then the agent's own progress messages.

  replay.py RUN_DIR --pick 1 2 3 ... --out replay.svg [--theme light|dark] [--title TEXT]

RUN_DIR is ~/.cache/vps-forge-bench/runs/<run-id>. --pick takes the indices of the agent's text
messages in agent.jsonl (run without --pick to list them). Messages are quoted, never rewritten:
each keeps its first sentences up to two lines, local paths are replaced by "~". Commands and
their output are left out on purpose: they would show the harness, not the server. The SVG
animates with CSS only (no script, no external resources), so GitHub shows it inside <img>.
"""
import argparse
import json
import pathlib
import re
import textwrap
from xml.sax.saxutils import escape

THEMES = {
    "light": dict(bg="#F3F5F7", frame="#D3DAE1", ink="#14202B", dim="#5E6E7E", you="#1F5FAD", ok="#1E7F5A", bar="#E6EBF0"),
    "dark": dict(bg="#0E161E", frame="#26333F", ink="#E4EBF1", dim="#8796A5", you="#6CA8F0", ok="#3FB683", bar="#16212C"),
}
COLS, FS, LH, PAD = 84, 14, 21, 26
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"


def messages(run):
    out = []
    for line in (run / "agent.jsonl").read_text().splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "assistant":
            out += [c["text"] for c in e["message"].get("content", []) if c.get("type") == "text" and c["text"].strip()]
    return out


def clean(text):
    text = text.strip().split("\n")[0]
    text = re.sub(r"(/home|/tmp|/run|/nix)/\S*", "~", text)
    text = re.sub(r"\*\*|`", "", text).replace("‑", "-")
    return text


def fit(text, width, lines=2):
    """The message's first sentences that fit in `lines` wrapped lines, cut at a sentence end."""
    parts = re.split(r"(?<=[.!?])\s+", text)
    keep = ""
    for p in parts:
        cand = (keep + " " + p).strip()
        if len(textwrap.wrap(cand, width)) > lines:
            break
        keep = cand
    return textwrap.wrap(keep or textwrap.shorten(text, width * lines, placeholder=" …"), width)


def render(prompt, steps, final, t, title):
    p = fit(prompt, COLS - 2, 3)
    rows = [("you", p[0])] + [("ucont", x) for x in p[1:]] + [("gap", "")]
    rows += [("step", fit(s, COLS - 2, 1)[0]) for s in steps]
    rows += [("gap", "")] + [("final", ln) for ln in fit(final, COLS - 2, 2)]
    width = PAD * 2 + int(COLS * FS * 0.6) + 10
    top = 46
    height = top + len(rows) * LH + 66
    per, hold = 1.1, 6.0
    shown = [i for i, (k, _) in enumerate(rows) if k != "gap"]
    # the prompt is there from the first frame, so a still capture (or a paused GIF viewer) never shows an empty box
    lead = sum(1 for i in shown if rows[i][0] in ("you", "ucont"))
    total = per * (len(shown) - lead + 1) + hold
    css, body = [], []
    for n, i in enumerate(shown):
        start = 0 if n < lead else 100 * ((n - lead + 1) * per) / total
        k, txt = rows[i]
        y = top + (i + 1) * LH
        color = {"you": t["you"], "ucont": t["you"], "final": t["ok"], "step": t["ink"]}[k]
        mark = {"you": "❯ ", "ucont": "  ", "step": "● ", "final": "✓ "}[k]
        fade = f"0%{{opacity:1}}" if start == 0 else f"0%,{start:.2f}%{{opacity:0}}{start + 0.8:.2f}%{{opacity:1}}"
        css.append(f"@keyframes l{n}{{{fade}97%{{opacity:1}}100%{{opacity:0}}}}"
                   f".l{n}{{animation:l{n} {total:.1f}s linear infinite}}")
        mcol = t["dim"] if k == "step" else color
        body.append(f'<text class="l{n}" x="{PAD}" y="{y}" xml:space="preserve"><tspan fill="{mcol}">{escape(mark)}</tspan>'
                    f'<tspan fill="{color}">{escape(txt)}</tspan></text>')
    style = (f"text{{font-family:{MONO};font-size:{FS}px;white-space:pre}}" + "".join(css) +
             "@media (prefers-reduced-motion: reduce){text{animation:none!important;opacity:1!important}}")
    dots = "".join(f'<circle cx="{PAD + 8 + 18 * i}" cy="22" r="5.5" fill="{t["frame"]}"/>' for i in range(3))
    foot = "".join(f'<text x="{PAD}" y="{height - 36 + 16 * j}" fill="{t["dim"]}" style="font-size:12px">'
                   f'{escape(x)}</text>' for j, x in enumerate(textwrap.wrap(title, 98)[:2]))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
            f'role="img" aria-label="{escape(title)}"><title>{escape(title)}</title><style>{style}</style>'
            f'<rect x="1" y="1" width="{width - 2}" height="{height - 2}" rx="12" fill="{t["bg"]}" stroke="{t["frame"]}"/>'
            f'<path d="M1 44 H{width - 1}" stroke="{t["frame"]}"/>{dots}{"".join(body)}{foot}</svg>')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run", type=pathlib.Path)
    ap.add_argument("--pick", type=int, nargs="*")
    ap.add_argument("--out", type=pathlib.Path)
    ap.add_argument("--theme", choices=THEMES, default="light")
    ap.add_argument("--prompt", help="the user's request as shown (default: a generic one-line request)")
    ap.add_argument("--title", default="Replay of a real benchmark run")
    a = ap.parse_args()
    msgs = [clean(m) for m in messages(a.run)]
    if not a.pick:
        for i, m in enumerate(msgs):
            print(i, m[:150])
        return
    steps, final = [msgs[i] for i in a.pick[:-1]], msgs[a.pick[-1]]
    prompt = a.prompt or "Set up my new VPS for production."
    a.out.write_text(render(prompt, steps, final, THEMES[a.theme], a.title))
    print(f"{a.out} ({a.out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
