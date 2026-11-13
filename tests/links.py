#!/usr/bin/env python3
"""Every relative link and image in the repository's Markdown files points at a file that exists.

Covers [text](target), ![alt](target), reference definitions ([id]: target) and the src, srcset and
href attributes of inline HTML. Fenced code blocks and inline code are skipped, and so are URLs
with a scheme (https:, mailto:) and pure in-page anchors (#section; tests/translations.py checks
the README's). Usage: tests/links.py (from anywhere; exits 1 on a broken link).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "node_modules", "dist", "results"}

MD_LINK = re.compile(r"!?\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$", re.M)
HTML_ATTR = re.compile(r"\b(?:src|href)\s*=\s*\"([^\"]+)\"")
SRCSET = re.compile(r"\bsrcset\s*=\s*\"([^\"]+)\"")


def markdown_files():
    try:
        out = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "*.md"],
                             cwd=ROOT, capture_output=True, check=True).stdout.decode()
        return sorted(p for p in out.split("\0") if p and os.path.isfile(os.path.join(ROOT, p)))
    except (OSError, subprocess.CalledProcessError):
        found = []
        for d, dirs, files in os.walk(ROOT):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            found += [os.path.relpath(os.path.join(d, f), ROOT) for f in files if f.endswith(".md")]
        return sorted(found)


def strip_code(text):
    text = re.sub(r"^(\s*)(```|~~~).*?^\1\2[^\n]*$", "", text, flags=re.S | re.M)
    return re.sub(r"`[^`\n]*`", "", text)


def targets(text):
    text = strip_code(text)
    out = MD_LINK.findall(text) + REF_DEF.findall(text) + HTML_ATTR.findall(text)
    for value in SRCSET.findall(text):
        out += [part.strip().split()[0] for part in value.split(",") if part.strip()]
    return out


def main():
    broken = []
    files = markdown_files()
    for rel in files:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            text = fh.read()
        for t in targets(text):
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", t) or t.startswith("#") or t.startswith("//"):
                continue
            path = re.split(r"[#?]", t, maxsplit=1)[0]
            if not path:
                continue
            base = ROOT if path.startswith("/") else os.path.dirname(os.path.join(ROOT, rel))
            if not os.path.exists(os.path.normpath(os.path.join(base, path.lstrip("/")))):
                broken.append(f"{rel}: {t}")
    for b in broken:
        print(f"  FAIL broken link {b}")
    if broken:
        return 1
    print(f"  ok   relative links and images resolve ({len(files)} Markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
