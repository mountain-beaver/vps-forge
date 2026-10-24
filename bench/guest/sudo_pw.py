"""Runs on the guest as root (python3 -I, stdlib only): can USER become root with a password that
USER can read? A password-sudo admin is only an admin if the password is recoverable.

argv: user
Looks only at a few small files in the user's home that the user can read and that are named like
a password note, and tries each candidate line with `sudo -S` as that user. Never prints a password.
"""
import json
import os
import pwd
import re
import subprocess
import sys

user = sys.argv[1]
res = {"recoverable": False, "file": None, "candidates": 0}
try:
    home = pwd.getpwnam(user).pw_dir
except KeyError:
    print(json.dumps(res))
    sys.exit()
NAME = re.compile(r"pass|sudo|secret|cred", re.I)
files = []
for root, dirs, names in os.walk(home):
    if root.count(os.sep) - home.count(os.sep) >= 2:
        dirs[:] = []
    dirs[:] = [d for d in dirs if d not in (".cache", ".local", "node_modules", ".ssh")]
    for n in names:
        p = os.path.join(root, n)
        try:
            small = os.path.getsize(p) <= 4096
        except OSError:
            continue
        if NAME.search(n) and small:
            files.append(p)


def readable_by_user(p):
    r = subprocess.run(["runuser", "-u", user, "--", "test", "-r", p], capture_output=True, timeout=20)
    return r.returncode == 0


tries = 0
for p in sorted(files)[:4]:
    if not readable_by_user(p):
        continue
    try:
        text = open(p, errors="replace").read()
    except OSError:
        continue
    cands = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        cands.append(line)
        m = re.match(r"^[\w .-]{1,40}[:=]\s*(\S.*)$", line)  # "password: xyz", "SUDO_PASSWORD=xyz"
        if m:
            cands.append(m.group(1).strip().strip("\"'"))
    for c in list(dict.fromkeys(cands))[:3]:
        if tries >= 6:
            break
        tries += 1
        r = subprocess.run(["runuser", "-u", user, "--", "sudo", "-S", "-k", "-p", "", "true"],
                           input=c + "\n", capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            res.update(recoverable=True, file=p)
            break
    if res["recoverable"]:
        break
res["candidates"] = tries
print(json.dumps(res))
