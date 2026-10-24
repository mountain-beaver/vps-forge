"""Runs on the guest as root (python3 -I, stdlib only, Python 3.10+): are the app's backups real?

argv: backup_dir data_dir probe_name started_at bound_at
  started_at: when the agent's run started; bound_at: only artifacts created up to then count
  (a rejudge boots the disk again, and a persistent timer may fire a fresh backup on that boot).
Prints one JSON object.

restorable: the probe file (e.g. upload-1.txt) is pulled out of a backup and its sha256 matches the
live copy in data_dir. Formats: plain/rsync copies, tar of any compression GNU tar can read, restic
and borg repositories (the password is looked up where an admin would leave it).
scheduled: an enabled timer with a next run, or an active cron entry, whose job is a backup of the
app: its command, or a script, env or config file it uses, calls a copy/backup tool and names the
backup or the data directory (or a backup repository there). Mount tables do not count.
"""
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

BACKUP, DATA, PROBE = sys.argv[1], sys.argv[2], sys.argv[3]
STARTED, BOUND = float(sys.argv[4]), float(sys.argv[5])
TOOLS = re.compile(r"(^|[\s/;|&(`'\"])(restic|borg|borgmatic|rsync|tar|rclone|kopia|duplicity|rdiff-backup|duplicati|cp|zstd|gzip)(\s|$|['\";|&)])")
TAR_EXT = (".tar", ".tar.gz", ".tgz", ".tar.zst", ".tzst", ".tar.zstd", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz", ".tar.lz4")
out = {"files_new": 0, "probe_sha": None, "restorable": False, "via": None, "tried": [], "scheduled": False, "jobs": [],
       "repos": []}


def run(cmd, env=None, timeout=120, data=None):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, env={**os.environ, **(env or {})}, input=data)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 255, b"", str(e).encode()


def sha(b):
    return hashlib.sha256(b).hexdigest()


def created(path):
    try:
        return os.lstat(path).st_ctime  # ctime cannot be set from user space: when it landed here
    except OSError:
        return None


def ok_time(path):
    c = created(path)
    return c is not None and c <= BOUND


def read_text(path, limit=262144):
    try:
        with open(path, "rb") as f:
            b = f.read(limit)
        return None if b"\0" in b else b.decode(errors="replace")
    except OSError:
        return None


def code_lines(text):
    """Lines that do something: no comments, no blank lines."""
    return [l for l in (text or "").splitlines() if l.strip() and not l.lstrip().startswith("#")]


try:
    with open(os.path.join(DATA, PROBE), "rb") as f:
        out["probe_sha"] = sha(f.read())
except OSError:
    pass


def matches(content):
    return out["probe_sha"] is not None and content is not None and sha(content) == out["probe_sha"]


# --- what is in the backup directory --------------------------------------------------------
plain, archives, repos = [], [], []
for root, dirs, files in os.walk(BACKUP):
    dirs[:] = [d for d in dirs if d != "lost+found"]
    in_repo = any(root == r or root.startswith(r + "/") for _, r in repos)
    if not in_repo and "config" in files and "keys" in dirs and "data" in dirs:
        repos.append(("restic", root))
        in_repo = True
    elif not in_repo and "config" in files and "data" in dirs and "[repository]" in (read_text(os.path.join(root, "config"), 4096) or ""):
        repos.append(("borg", root))
        in_repo = True
    for n in files:
        p = os.path.join(root, n)
        c = created(p)
        if c is not None and STARTED <= c <= BOUND:
            out["files_new"] += 1
        if in_repo:
            continue  # repository internals: opened with the tool below
        if n == PROBE:
            plain.append(p)
        elif n.lower().endswith(TAR_EXT):
            archives.append(p)
out["repos"] = [f"{k}:{p}" for k, p in repos]


def found(via, where):
    out["restorable"], out["via"] = True, f"{via}:{where}"


for p in plain:
    if ok_time(p):
        try:
            with open(p, "rb") as f:
                if matches(f.read()):
                    found("copy", p)
                    break
        except OSError:
            pass
        out["tried"].append(f"copy:{p}")

if not out["restorable"]:
    # newest first; GNU tar picks the decompressor from the archive's content when reading
    archives = sorted((a for a in archives if ok_time(a)), key=lambda a: -os.lstat(a).st_mtime)[:12]
    for a in archives:
        rc, listing, _ = run(["tar", "-tf", a], timeout=300)
        members = [m for m in listing.decode(errors="replace").splitlines() if m.rstrip("/").split("/")[-1] == PROBE]
        out["tried"].append(f"tar:{a}:{'listed' if rc == 0 else 'unreadable'}:{len(members)}")
        for m in members[:3]:
            rc, content, _ = run(["tar", "-xOf", a, m], timeout=300)
            if rc == 0 and matches(content):
                found("tar", f"{a}#{m}")
                break
        if out["restorable"]:
            break

# --- secrets an admin would leave for a scheduled restic/borg job -----------------------------
SECRET_RE = re.compile(
    r"(RESTIC_PASSWORD_FILE|RESTIC_PASSWORD_COMMAND|RESTIC_PASSWORD|RESTIC_REPOSITORY|BORG_PASSPHRASE|BORG_PASSCOMMAND"
    r"|BORG_REPO)\s*[=:]\s*(\"[^\"]*\"|'[^']*'|\S+)")
FLAG_RE = re.compile(r"(--password-file|--password-command|-p)[ =](\"[^\"]*\"|'[^']*'|\S+)")


def unquote(v):
    v = v.strip().rstrip(";")
    try:
        parts = shlex.split(v)
        return parts[0] if len(parts) == 1 else v.strip("\"'")
    except ValueError:
        return v.strip("\"'")


def unit_files():
    for d in ("/etc/systemd/system", "/usr/local/lib/systemd/system", "/root/.config/systemd/user"):
        for root, _, files in os.walk(d):
            for n in files:
                yield os.path.join(root, n)


def referenced_files(text):
    """Absolute paths a unit or script points at (scripts it runs, env files it reads)."""
    paths = set()
    for tok in re.findall(r"(/[\w@.+/-]+)", text or ""):
        tok = tok.rstrip(".")
        if os.path.isfile(tok) and not tok.startswith(("/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/", "/usr/lib/", "/lib/", "/proc/", "/dev/")):
            paths.add(tok)
    return paths


secret_sources = set()
for path in list(unit_files()):
    secret_sources.add(path)
for d in ("/etc", "/root", "/usr/local/bin", "/usr/local/sbin", "/opt", "/srv"):
    for root, dirs, files in os.walk(d):
        if root.count(os.sep) - d.count(os.sep) >= 4:
            dirs[:] = []
        dirs[:] = [x for x in dirs if x not in ("ssl", "alternatives", "docker", "containerd", ".cache", "node_modules", "lost+found")]
        for n in files:
            if any(k in n.lower() for k in ("restic", "borg", "backup", "pass", "env", ".sh", "secret", "key")) or root.endswith(("restic", "borg", "backup")):
                secret_sources.add(os.path.join(root, n))
# one level of indirection: scripts and env files those files name
for path in list(secret_sources):
    t = read_text(path)
    if t and re.search(r"restic|borg|backup", t, re.I):
        secret_sources |= referenced_files(t)

pw_files, pw_values, pw_cmds, borg_pass, borg_cmds = set(), set(), set(), set(), set()
for path in secret_sources:
    t = read_text(path, 65536)
    if not t:
        continue
    for line in code_lines(t):
        for k, v in SECRET_RE.findall(line):
            v = unquote(v)
            if "$" in v:
                continue
            if k == "RESTIC_PASSWORD_FILE":
                pw_files.add(v)
            elif k == "RESTIC_PASSWORD":
                pw_values.add(v)
            elif k == "RESTIC_PASSWORD_COMMAND":
                pw_cmds.add(v)
            elif k == "BORG_PASSPHRASE":
                borg_pass.add(v)
            elif k == "BORG_PASSCOMMAND":
                borg_cmds.add(v)
        if re.search(r"\brestic\b", line):
            for flag, v in FLAG_RE.findall(line):
                v = unquote(v)
                if "$" in v:
                    continue
                (pw_cmds if flag == "--password-command" else pw_files).add(v)
pw_files |= {"/root/.restic-password", "/root/.restic_password", "/etc/restic/password", "/etc/restic/restic.pass",
             "/etc/restic/repo.pass", "/root/.config/restic/password"}
pw_files = {p for p in pw_files if os.path.isfile(p)}


def restic_try(repo, env):
    rc, ls, _ = run(["restic", "-r", repo, "--no-lock", "--json", "ls", "latest"], env=env, timeout=300)
    if rc != 0:
        return None
    for line in ls.decode(errors="replace").splitlines():
        try:
            node = json.loads(line)
        except ValueError:
            continue
        if node.get("type") == "file" and node.get("name") == PROBE:
            rc, content, _ = run(["restic", "-r", repo, "--no-lock", "dump", "latest", node["path"]], env=env, timeout=300)
            if rc == 0 and matches(content):
                return node["path"]
    return False


def borg_try(repo, env):
    env = {**env, "BORG_RELOCATED_REPO_ACCESS_IS_OK": "yes", "BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK": "yes"}
    rc, names, _ = run(["borg", "list", "--short", repo], env=env, timeout=300)
    if rc != 0:
        return None
    archives_ = names.decode(errors="replace").split()
    for arch in reversed(archives_[-3:]):
        rc, members, _ = run(["borg", "list", "--short", f"{repo}::{arch}"], env=env, timeout=300)
        for m in members.decode(errors="replace").splitlines():
            if m.split("/")[-1] == PROBE:
                rc, content, _ = run(["borg", "extract", "--stdout", f"{repo}::{arch}", m], env=env, timeout=300)
                if rc == 0 and matches(content):
                    return f"{arch}#{m}"
    return False


for kind, repo in repos:
    if out["restorable"]:
        break
    if kind == "restic":
        envs = ([{"RESTIC_PASSWORD_FILE": p} for p in sorted(pw_files)] + [{"RESTIC_PASSWORD": v} for v in sorted(pw_values)]
                + [{"RESTIC_PASSWORD_COMMAND": c} for c in sorted(pw_cmds)])
        try_ = restic_try
    else:
        envs = ([{"BORG_PASSPHRASE": v} for v in sorted(borg_pass)] + [{"BORG_PASSCOMMAND": c} for c in sorted(borg_cmds)]
                + [{"BORG_PASSPHRASE": ""}])
        try_ = borg_try
    opened = False
    for env in envs[:12]:
        r = try_(repo, {**env, "HOME": "/root"})
        if r is None:
            continue
        opened = True
        if r:
            found(kind, f"{repo}#{r}")
        break
    out["tried"].append(f"{kind}:{repo}:{'opened' if opened else 'no password worked' if envs else 'no password found'}")

# --- is a backup scheduled? ------------------------------------------------------------------
def is_backup_job(texts):
    blob = "\n".join("\n".join(code_lines(t)) for t in texts if t)
    names_dir = any(re.search(rf"{re.escape(x.rstrip('/'))}(/|\b|$)", blob) for x in (BACKUP, DATA))
    return names_dir and bool(TOOLS.search(blob))


def is_script(path):
    try:
        if os.access(path, os.X_OK):
            return True
        with open(path, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


MOUNT_TABLES = ("/etc/fstab", "/etc/mtab", "/proc/mounts")  # name every mount point: not a job's config


def job_texts(cmdline, env_files=()):
    """The job's command, its env files, the scripts it runs and the config files those name (read,
    not followed further). Mount tables are skipped: they name the backup volume for any job."""
    texts, seen = [cmdline], set()
    for e in env_files:
        t = read_text(e)
        if t:
            texts.append(t)
    queue = list(referenced_files(cmdline))
    while queue and len(seen) < 12:
        p = queue.pop(0)
        if p in seen or p in MOUNT_TABLES:
            continue
        seen.add(p)
        t = read_text(p)
        if t is None:
            continue
        texts.append(t)
        if is_script(p):
            queue += [q for q in referenced_files("\n".join(code_lines(t))) if q not in seen]
    return texts


def show(unit, *props):
    rc, o, _ = run(["systemctl", "show", unit, *[f"-p{p}" for p in props]], timeout=30)
    return dict(l.split("=", 1) for l in o.decode(errors="replace").splitlines() if "=" in l)


rc, o, _ = run(["systemctl", "list-units", "--type=timer", "--all", "--plain", "--no-legend", "--no-pager"], timeout=60)
for line in o.decode(errors="replace").splitlines():
    timer = line.split()[0] if line.split() else ""
    if not timer.endswith(".timer"):
        continue
    t = show(timer, "ActiveState", "UnitFileState", "NextElapseUSecRealtime", "NextElapseUSecMonotonic", "Triggers", "FragmentPath")
    nxt = (t.get("NextElapseUSecRealtime") or "").strip() not in ("", "0", "n/a") or \
          (t.get("NextElapseUSecMonotonic") or "").strip() not in ("", "0", "infinity", "n/a")
    if t.get("ActiveState") != "active" or not nxt:
        continue
    for svc in (t.get("Triggers") or "").split():
        s = show(svc, "ExecStart", "Environment", "EnvironmentFiles", "FragmentPath")
        cmd = " ".join(re.findall(r"argv\[\]=([^;]*)", s.get("ExecStart", ""))) or s.get("ExecStart", "")
        envf = re.findall(r"(/\S+)", re.sub(r"\(ignore_errors=\w+\)", "", s.get("EnvironmentFiles", "")))
        texts = job_texts(cmd + "\n" + s.get("Environment", ""), envf)
        if is_backup_job(texts):
            out["scheduled"] = True
            out["jobs"].append(f"timer:{timer}->{svc}")

CRON_LINE = re.compile(r"^\s*(@\w+|[\d*/,\-]+\s+[\d*/,\-]+\s+[\d*/,\-]+\s+[\w*/,\-]+\s+[\w*/,\-]+)\s+(.*)$")
cron_on = any(run(["systemctl", "is-active", "--quiet", u], timeout=20)[0] == 0 for u in ("cron", "crond", "cronie"))
if cron_on:
    tabs = [("/etc/crontab", True)]
    if os.path.isdir("/etc/cron.d"):
        tabs += [(os.path.join("/etc/cron.d", n), True) for n in sorted(os.listdir("/etc/cron.d"))
                 if os.path.isfile(os.path.join("/etc/cron.d", n))]
    sp = "/var/spool/cron/crontabs"
    if os.path.isdir(sp):
        tabs += [(os.path.join(sp, n), False) for n in sorted(os.listdir(sp))]
    for path, system in tabs:
        if os.path.basename(path).startswith(".") or ("." in os.path.basename(path) and path.startswith("/etc/cron.d/")):
            continue  # cron ignores such names in cron.d
        for line in code_lines(read_text(path)):
            m = CRON_LINE.match(line)
            if not m or "=" in line.split()[0]:
                continue
            cmd = m.group(2)
            if system:  # system crontabs carry a user field
                cmd = cmd.split(None, 1)[1] if len(cmd.split(None, 1)) > 1 else ""
            if "run-parts" in cmd:
                continue  # the periodic directories are checked below, with run-parts' own rules
            if is_backup_job(job_texts(cmd)):
                out["scheduled"] = True
                out["jobs"].append(f"cron:{path}")
# /etc/cron.daily and friends: run by cron (or anacron) through run-parts, which skips names with dots
periodic_on = cron_on or run(["systemctl", "is-active", "--quiet", "anacron.timer"], timeout=20)[0] == 0
for d in ("/etc/cron.hourly", "/etc/cron.daily", "/etc/cron.weekly"):
    if not periodic_on or not os.path.isdir(d):
        continue
    rc, o, _ = run(["run-parts", "--test", d], timeout=20)
    for path in o.decode(errors="replace").split():
        if is_backup_job(job_texts(path)):
            out["scheduled"] = True
            out["jobs"].append(f"periodic:{path}")

out["tried"] = out["tried"][:20]
print(json.dumps(out))
