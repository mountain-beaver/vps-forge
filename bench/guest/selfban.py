"""Runs on the guest as root (python3 -I, stdlib only): was this address banned, and when?

argv: ip window_start window_end   (epoch seconds; the agent's run)
Prints one JSON object. Every source is read independently, so a purged fail2ban database or a
journal lost on reboot does not hide a ban that another source still shows:
  - fail2ban's sqlite database (table bans: one row per ban, kept for dbpurgeage, default 1 day);
  - fail2ban's own log, /var/log/fail2ban.log* (local time of the guest), and its journal;
  - CrowdSec alerts for the address (each one carries its decisions).
"""
import datetime
import glob
import gzip
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

IP, START, END = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
events = {}  # source -> [epoch, ...]


def add(src, t):
    events.setdefault(src, []).append(float(t))


db = "/var/lib/fail2ban/fail2ban.sqlite3"
if os.path.exists(db):
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
        for (t,) in con.execute("SELECT timeofban FROM bans WHERE ip = ?", (IP,)):
            add("fail2ban_db", t)
        con.close()
    except sqlite3.Error as e:
        events.setdefault("errors", []).append(f"db: {e}")

ban = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)[,.]\d+ .*\bBan " + re.escape(IP) + r"\b")
for path in sorted(glob.glob("/var/log/fail2ban.log*")):
    try:
        opener = gzip.open if path.endswith(".gz") else open
        with opener(path, "rt", errors="replace") as f:
            for line in f:
                m = ban.match(line)
                if m:  # the guest's local time, as fail2ban wrote it
                    add("fail2ban_log", time.mktime(datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timetuple()))
    except OSError:
        pass

try:
    p = subprocess.run(["journalctl", "-u", "fail2ban", "--no-pager", "-o", "short-unix", "-g", f"Ban {IP}"],
                       capture_output=True, text=True, timeout=120)
    for line in p.stdout.splitlines():
        m = re.match(r"^(\d+\.\d+) ", line)
        if m and re.search(r"\bBan " + re.escape(IP) + r"\b", line):
            add("fail2ban_journal", m.group(1))
except (OSError, subprocess.TimeoutExpired):
    pass

try:
    p = subprocess.run(["cscli", "alerts", "list", "--ip", IP, "-o", "json", "--limit", "0"],
                       capture_output=True, text=True, timeout=120)
    for a in json.loads(p.stdout or "[]") or []:
        if not a.get("decisions"):
            continue
        ts = a.get("created_at") or a.get("start_at") or ""
        try:
            add("crowdsec", datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
        except ValueError:
            add("crowdsec", 0)
except (OSError, subprocess.TimeoutExpired, ValueError):
    pass

res = {"sources": {}, "during": 0, "outside": 0, "first_ban": None}
errors = events.pop("errors", [])
for src, ts in events.items():
    inside = sorted(t for t in ts if START <= t <= END)
    res["sources"][src] = {"during": len(inside), "outside": len(ts) - len(inside)}
    if inside and (res["first_ban"] is None or inside[0] < res["first_ban"]):
        res["first_ban"] = inside[0]
# the database and the log describe the same bans: count them once, from the best source present
for src in ("fail2ban_db", "fail2ban_log", "fail2ban_journal"):
    if src in res["sources"]:
        res["during"] += res["sources"][src]["during"]
        res["outside"] += res["sources"][src]["outside"]
        break
if "crowdsec" in res["sources"]:
    res["during"] += res["sources"]["crowdsec"]["during"]
    res["outside"] += res["sources"]["crowdsec"]["outside"]
if res["first_ban"] is not None:
    res["first_ban"] = datetime.datetime.fromtimestamp(res["first_ban"], datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
res["errors"] = errors
print(json.dumps(res))
