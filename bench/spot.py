#!/usr/bin/env python3
"""Chart for a spot check of another model next to the Opus benchmark on the same distro and scenarios:
    python3 bench/spot.py --tag zc2 --model GLM-5.3 --out docs/bench
writes spot-<model>.svg and spot-<model>-dark.svg (lowercased, e.g. spot-glm-5.3.svg)."""
import argparse
import pathlib

from report import BENCH, SCEN_LABEL, THEMES, Svg, bar_top, load, mean


def spot_chart(opus, other, model, distro, scenarios, theme):
    t = THEMES[theme]
    W, H = 880, 380
    svg = Svg(W, H, t)
    left, right, top, bottom = 48, 20, 92, 76
    ph = H - top - bottom
    n_opus = max(len(opus.get((distro, s, a), [])) for s in scenarios for a in ("baseline", "skill"))
    n_other = max(len(other.get((distro, s, a), [])) for s in scenarios for a in ("baseline", "skill"))
    svg.text(left, 28, f"Checklist score on {distro.replace('-', ' ').title()}: Claude Opus 5.5 and {model}", 16, weight=600)
    svg.text(left, 50, f"Opus: mean of {n_opus} runs, whisker worst to best · {model}: {n_other} run{'s' if n_other > 1 else ''} "
             f"per bar, a spot check, not a benchmark", 12.5, "ink2")
    for v in (0, 25, 50, 75, 100):
        y = top + ph * (1 - v / 100)
        svg.line(left, y, W - right, y, "grid", 1)
        svg.text(left - 8, y + 4, v, 11, "ink2", "end")
    gw = (W - left - right) / len(scenarios)
    bw = 46
    for i, s in enumerate(scenarios):
        gx = left + i * gw + gw / 2
        for k, (name, runs) in enumerate((("Opus 5.5", opus), (model, other))):
            sx = gx + (k - 0.5) * (2 * bw + 44)  # centre of this model's pair
            for j, (arm, fill) in enumerate((("baseline", "base"), ("skill", "skill"))):
                vals = [r["judge"]["score"]["score"] for r in runs.get((distro, s, arm), [])]
                x = sx + (j - 1) * (bw + 4) + 2
                m = mean(vals)
                if m is None:
                    svg.text(x + bw / 2, top + ph - 6, "n/a", 11, "ink2", "middle")
                    continue
                h = ph * m / 100
                bar_top(svg, x, top + ph - h, bw, h, fill)
                lo, hi = min(vals), max(vals)
                if hi > lo:
                    y_lo, y_hi = top + ph * (1 - lo / 100), top + ph * (1 - hi / 100)
                    for x1, y1, x2, y2 in ((x + bw / 2, y_lo, x + bw / 2, y_hi), (x + bw / 2 - 5, y_lo, x + bw / 2 + 5, y_lo),
                                           (x + bw / 2 - 5, y_hi, x + bw / 2 + 5, y_hi)):
                        svg.line(x1, y1, x2, y2, "ink", 1.5)
                svg.text(x + bw / 2, top + ph * (1 - max(m, hi) / 100) - 8, m, 14 if arm == "skill" else 12.5, "ink", "middle",
                         700 if arm == "skill" else 500)
            svg.text(sx, top + ph + 18, name, 12.5, "ink2", "middle", 500)
        svg.text(gx, top + ph + 38, SCEN_LABEL[s], 13, "ink", "middle", 600)
    lx = left
    for label, fill in (("Without the skill", "base"), ("With vps-forge", "skill")):
        svg.rect(lx, H - 22, 12, 12, fill, 2)
        svg.text(lx + 18, H - 12, label, 12.5, "ink2")
        lx += 18 + len(label) * 7 + 26
    return svg.render(f"Checklist score with and without vps-forge: Claude Opus 5.5 and {model}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="run tag of the spot check, e.g. zc2")
    ap.add_argument("--model", required=True, help="model name for the labels, e.g. GLM-5.3")
    ap.add_argument("--opus-tag", default="v3")
    ap.add_argument("--out", default=str(BENCH.parent / "docs" / "bench"))
    a = ap.parse_args()
    other, _, _ = load(a.tag)
    opus, _, _ = load(a.opus_tag)
    distros = sorted({d for d, _, _ in other})
    scenarios = [s for s in SCEN_LABEL if any(k[1] == s for k in other)]
    if len(distros) != 1:
        raise SystemExit(f"expected one distro in --tag {a.tag}, found {distros}")
    out = pathlib.Path(a.out)
    for theme in THEMES:
        sfx = "" if theme == "light" else "-dark"
        f = out / f"spot-{a.model.lower()}{sfx}.svg"
        f.write_text(spot_chart(opus, other, a.model, distros[0], scenarios, theme))
        print(f)


if __name__ == "__main__":
    main()
