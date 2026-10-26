#!/usr/bin/env python3
"""Check the README translations against README.md.

Fails when a translation's structure drifts from the English file: a link, image, code command,
table row or <details> block missing or added, an in-page anchor with no matching heading, or a
missing language switcher. Only warns when README.md changed since the translation was made
(the sha256 in its "translation of README.md" comment): translations may lag, English is right.
"""
import glob
import hashlib
import os
import re
import sys

SRC = "README.md"
ISSUES = "https://github.com/mountain-beaver/vps-forge/issues"
MARK = re.compile(r"<!-- translation of README\.md, source sha256: ([0-9a-f]{12}|PENDING) -->")


def slug(heading):
    # GitHub's rule: lowercase, keep letters and digits of any script, hyphens, underscores and
    # spaces, then spaces become hyphens.
    s = "".join(ch for ch in heading.strip().lower() if ch.isalnum() or ch in "-_ ")
    return s.replace(" ", "-")


def parse(path):
    text = open(path, encoding="utf-8").read()
    prose, code, block, fence = [], [], [], False
    for line in text.splitlines():
        if line.startswith("```"):
            if fence:
                code.append(block)
                block = []
            fence = not fence
            continue
        if fence:
            # Commands stay verbatim; comments after them are translated.
            cmd = re.sub(r"(^|\s)#\s.*$", "", line).rstrip()
            # A file tree: names stay, the descriptions after them are translated.
            if "\u2500\u2500 " in cmd:
                cmd = re.match(r"^[\u2502\u251c\u2514\u2500\s]*\S+", cmd).group(0)
            elif cmd.startswith("\u2502"):
                cmd = ""
            if cmd:
                block.append(cmd)
        else:
            prose.append(line)
    body = "\n".join(prose)
    slugs, seen = set(), {}
    for h in re.findall(r"^#{1,6}\s+(.+?)\s*#*$", body, re.M):
        s = slug(h)
        n = seen.get(s, 0)
        seen[s] = n + 1
        slugs.add(s if n == 0 else f"{s}-{n}")
    targets = re.findall(r'(?:href|src|srcset)="([^"]+)"|\]\(([^)\s]+)\)', body)
    targets = [a or b for a, b in targets]
    return {
        "text": text,
        "code": code,
        # the translation note links the issue tracker; English has no such note
        "links": [t for t in targets if not t.startswith("#") and not re.fullmatch(r"README(\.[\w-]+)?\.md", t)
                  and t != ISSUES],
        "anchors": [t[1:] for t in targets if t.startswith("#")],
        "slugs": slugs,
        "rows": sum(1 for line in prose if line.lstrip().startswith("|")),
        "details": body.count("<details>"),
        "switch": set(re.findall(r'href="(README(?:\.[\w-]+)?\.md)"', body.split("\n\n", 1)[0])),
    }


def main():
    fail = 0
    warn = os.environ.get("GITHUB_ACTIONS") == "true"
    files = sorted(glob.glob("README.*.md"))
    src = parse(SRC)
    digest = hashlib.sha256(src["text"].encode()).hexdigest()[:12]
    names = {SRC, *files}

    def bad(path, msg):
        nonlocal fail
        fail = 1
        print(f"  FAIL {path}: {msg}")

    for path, d in [(SRC, src)] + [(f, parse(f)) for f in files]:
        for a in d["anchors"]:
            if a not in d["slugs"]:
                bad(path, f"#{a} matches no heading")
        missing = names - {path} - d["switch"]
        if missing:
            bad(path, f"the language switcher on the first line doesn't link {', '.join(sorted(missing))}")
        if path == SRC:
            continue
        for key, what in (("links", "links and images"), ("code", "code commands")):
            if d[key] != src[key]:
                extra = [x for x in d[key] if x not in src[key]][:3]
                lost = [x for x in src[key] if x not in d[key]][:3]
                bad(path, f"{what} differ from {SRC} (missing {lost or '-'}, extra {extra or '-'}, or a different order)")
        for key, what in (("rows", "table rows"), ("details", "<details> blocks")):
            if d[key] != src[key]:
                bad(path, f"{d[key]} {what}, {SRC} has {src[key]}")
        m = MARK.search(d["text"])
        if not m:
            bad(path, "no '<!-- translation of README.md, source sha256: ... -->' comment")
        elif m.group(1) != digest:
            msg = f"{path} was translated from an older README.md (sha256 {m.group(1)}, now {digest}); update it and the hash"
            print(f"::warning file={path}::{msg}" if warn else f"  warn {msg}")
    if not fail:
        print(f"  ok   README translations match {SRC} in structure ({', '.join(files) or 'none'})")
    return fail


if __name__ == "__main__":
    sys.exit(main())
