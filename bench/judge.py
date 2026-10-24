"""Independent judge for one benchmark cell.

Nothing here uses the skill's own scripts: the verdict comes from what an outsider can observe
(SSH logins with the user's key, offered auth methods, ssh-audit, which ports answer from outside)
plus facts read through the guest agent (the "provider console"), plus Lynis as a third-party score.
"""
import base64
import json
import pathlib
import re
import shlex
import socket
import subprocess
import time

from vm import PORTS, PUBLIC_IP, SOURCES, SSH_OPTS, sh

JUDGE_VERSION = 3
GUEST = pathlib.Path(__file__).resolve().parent / "guest"
# Connections without a source address come from PUBLIC_IP: the admin's own IP, which the agent
# under test used too. Only logins that should succeed go out from there (see SOURCES in vm.py).
# A rejudge swaps in its own set of addresses (use_sources), so bans left by the first judge on the
# same disk cannot skew it.
SRC = dict(SOURCES)


def use_sources(sources):
    SRC.clear()
    SRC.update(sources)


def guest_py(ga, name, *args, timeout=600):
    """Run one of the stdlib-only scripts in guest/ on the guest as root; returns its JSON or None."""
    b64 = base64.b64encode((GUEST / name).read_bytes()).decode()
    argv = " ".join(shlex.quote(str(a)) for a in args)
    rc, out, err = ga.run(f'python3 -I -c "$(echo {b64} | base64 -d)" {argv}', timeout=timeout)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise RuntimeError(f"guest/{name} failed rc={rc}: {err[-600:]}")


def _bind(src):
    return ["-b", src] if src else []


def _connect(port, src, timeout):
    return socket.create_connection((PUBLIC_IP, port), timeout=timeout, source_address=(src, 0) if src else None)


def ssh_ok(key, user, port, cmd="true", src=None):
    r = sh(["ssh", *SSH_OPTS, *_bind(src), "-i", str(key), "-p", str(port), "-l", user, "--", PUBLIC_IP, cmd], timeout=40)
    return r.returncode == 0, (r.stdout + r.stderr).strip()[-300:]


def offered_methods(port, src):
    r = sh(["ssh", *SSH_OPTS, "-b", src, "-o", "PreferredAuthentications=none", "-o", "PubkeyAuthentication=no",
            "-p", str(port), f"vpsforge-judge@{PUBLIC_IP}", "true"], timeout=30)
    m = re.search(r"Permission denied \(([^)]*)\)", r.stderr)
    return m.group(1).split(",") if m else None


def banned(ga, ip):
    """Is this address blocked in the guest's packet filter (fail2ban, crowdsec, a manual rule)?"""
    rc, out, _ = ga.run(f"nft list ruleset 2>/dev/null | grep -cF '{ip}'; iptables-save 2>/dev/null | grep -cF '{ip}'; "
                        f"ipset list 2>/dev/null | grep -cF '{ip}'; true")
    return any(int(x) > 0 for x in out.split() if x.isdigit())


def probe(port, timeout=4.0, src=None):
    """True if something answers on the port from outside (banner or reply to a probe)."""
    src = src or SRC["ports"]
    try:
        s = _connect(port, src, timeout)
    except OSError:
        return False
    s.settimeout(timeout)
    try:
        try:
            data = s.recv(64)  # SSH, MySQL, SMTP speak first
            if data:
                return True
            return False  # closed right away (slirp: guest refused)
        except socket.timeout:
            pass
        payload = bytes.fromhex("0000000804d2162f") if port == 5432 else b"GET / HTTP/1.0\r\nHost: x\r\n\r\n"
        try:
            s.sendall(payload)
            return bool(s.recv(64))
        except OSError:
            return False
    finally:
        s.close()


def http_get(port, timeout=8, src=None):
    src = src or SRC["ports"]
    try:
        s = _connect(port, src, timeout)
        s.settimeout(timeout)
        s.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        return data.decode(errors="replace")
    except OSError:
        return ""


def guest_listeners(ga):
    """TCP ports the guest listens on beyond loopback (what a public IP would expose)."""
    rc, out, _ = ga.run("ss -Htln 2>/dev/null | awk '{print $4}'", timeout=30)
    ports = set()
    for addr in out.split():
        host, _, port = addr.rpartition(":")
        if port.isdigit() and 0 < int(port) < 65536 and not host.startswith(("127.", "[::1]", "::1")) and "%lo" not in host:
            ports.add(int(port))
    return ports


def candidate_ports(vm, published):
    """PORTS, plus the ports published during the run (PortWatcher), plus whatever the guest listens
    on now. New ones are published before probing, so a service on an odd port is seen from outside.
    `published` is the watcher's set and is updated in place."""
    for p in sorted(guest_listeners(vm.qga) - set(published)):
        vm.hostfwd_add(p)
        published.add(p)
    return sorted(set(PORTS) | set(published))


def ssh_ports(src, ports=PORTS):
    return [p for p in ports if _is_ssh(p, src)]


def _is_ssh(port, src):
    try:
        s = _connect(port, src, 3)
        s.settimeout(4)
        b = s.recv(32)
        s.close()
        return b.startswith(b"SSH-")
    except OSError:
        return False


def login_users(ga):
    rc, out, _ = ga.run("getent passwd | awk -F: '($3>=1000 && $3<60000) || $1==\"root\" {print $1\":\"$7}'")
    users = []
    for line in out.splitlines():
        name, _, shell = line.partition(":")
        # names come from a guest the agent controlled and end up in ssh's argv on the host
        if shell and not re.search(r"(nologin|false)$", shell) and re.fullmatch(r"[a-z_][a-z0-9_.-]{0,31}", name):
            users.append(name)
    return users


# One login answers both questions: did the key get in, and can this account become root without a
# prompt? A forced command (cloud-init's "Please login as ...") never prints the marker: no login.
LOGIN_CMD = "echo LOGIN_OK; sudo -n true </dev/null >/dev/null 2>&1 && echo SUDO_OK; exit 0"


def login(key, user, port, src=None):
    """(logged_in, root_without_password) for one SSH login with the user's key."""
    r = sh(["ssh", *SSH_OPTS, *_bind(src), "-i", str(key), "-p", str(port), "-l", user, "--", PUBLIC_IP, LOGIN_CMD],
           timeout=40)
    lines = r.stdout.split()
    return "LOGIN_OK" in lines, user == "root" or "SUDO_OK" in lines


_pw_cache = {}


def password_sudo(ga, user):
    """Password sudo counts only if the password is recoverable by that user (a note they can read)."""
    if user not in _pw_cache:
        _pw_cache[user] = guest_py(ga, "sudo_pw.py", user, timeout=300)
    return _pw_cache[user]


def become_root(ga, key, user, port, src):
    """How this login reaches root: "root", "nopasswd", "password-file", or None. None for the
    login itself failing as well (see the first element)."""
    logged, nopw = login(key, user, port, src)
    if not logged:
        return False, None
    if user == "root":
        return True, "root"
    if nopw:
        return True, "nopasswd"
    pw = password_sudo(ga, user)
    return True, ("password-file" if pw and pw.get("recoverable") else None)


def key_users(ga, key):
    """Accounts whose authorized keys hold the user's key: the only logins worth trying, so the judge
    does not pile up failed logins of its own."""
    body = pathlib.Path(str(key) + ".pub").read_text().split()[1]
    users = login_users(ga)
    rc, out, _ = ga.run(f"for u in {' '.join(users)}; do h=$(getent passwd $u | cut -d: -f6); "
                        f"grep -qsF '{body}' $h/.ssh/authorized_keys $h/.ssh/authorized_keys2 && echo user:$u; done; "
                        f"grep -rlsF '{body}' /etc/ssh 2>/dev/null | sed 's/^/etc:/'; true")
    found = {l[5:] for l in out.splitlines() if l.startswith("user:")}
    for path in (l[4:] for l in out.splitlines() if l.startswith("etc:")):
        named = [u for u in users if re.search(rf"(^|[/._-]){re.escape(u)}($|[/._-])", path)]
        found |= set(named) if named else set(users)
    return [u for u in users if u in found]


def access(ga, key, ports, admin_src=None, root_src=None):
    """Which (user, port) pairs accept the user's key, and can one of them become root (the admin can
    administer the box; being in the sudo group is not enough). Root is tried from its own address:
    refusing it is the expected, logged-as-failure outcome."""
    root_src = root_src or SRC["root"]
    ok = []
    users = key_users(ga, key)
    for port in ports:
        for user in users:
            logged, how = become_root(ga, key, user, port, root_src if user == "root" else admin_src)
            if logged:
                ok.append({"user": user, "port": port, "sudo": how})
    admin = any(x["sudo"] for x in ok)
    return {"logins": ok, "admin_access": admin, "key_users": users}


def requested_login(ga, key, user, port, src):
    """The login the user asked for works and can become root (sudo -n, or a recoverable password)."""
    logged, how = become_root(ga, key, user, port, src)
    return bool(logged and how)


def run_ssh_audit(port, src=None):
    """ssh-audit cannot pick a source address: bridge it through socat bound to one."""
    src = src or SRC["audit"]
    with socket.socket() as t:
        t.bind(("127.0.0.1", 0))
        lp = t.getsockname()[1]
    bridge = subprocess.Popen(["socat", f"TCP-LISTEN:{lp},bind=127.0.0.1,fork,reuseaddr",
                               f"TCP:{PUBLIC_IP}:{port},bind={src}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(0.5)
        r = sh(["ssh-audit", "-j", "--skip-rate-test", "-p", str(lp), "127.0.0.1"], timeout=120)
    finally:
        bridge.terminate()
    try:
        d = json.loads(r.stdout)
    except ValueError:
        return None
    fails = warns = 0
    for sect in ("kex", "key", "enc", "mac"):
        for item in d.get(sect, []) or []:
            notes = item.get("notes", {}) or {}
            fails += len(notes.get("fail", []) or [])
            warns += len(notes.get("warn", []) or [])
    return {"fail": fails, "warn": warns}


def firewall_active(ga):
    rc, out, _ = ga.run("(command -v ufw >/dev/null && ufw status | head -n1) ; "
                        "nft list ruleset 2>/dev/null | grep -cE 'hook input .*policy drop' ; "
                        "iptables -S INPUT 2>/dev/null | head -n1")
    return "Status: active" in out or bool(re.search(r"^[1-9]", out, re.M)) or "-P INPUT DROP" in out


def updates_enabled(ga):
    rc, out, _ = ga.run("dpkg -s unattended-upgrades >/dev/null 2>&1 && echo pkg; "
                        "apt-config dump | grep -E '^APT::Periodic::Unattended-Upgrade \"1\"' >/dev/null && echo periodic; "
                        "apt-config dump | grep -E '^APT::Periodic::Update-Package-Lists \"1\"' >/dev/null && echo lists; "
                        "systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null")
    return "pkg" in out and "periodic" in out and "lists" in out and "enabled" in out


def intrusion(ga, ports):
    """A brute force from one address: is that address banned at the firewall afterwards, while
    another address still reaches SSH? Attempts are spaced out, so OpenSSH's own short per-source
    penalties (9.8+) neither hide the attempts from fail2ban nor pass for a ban."""
    rc, out, _ = ga.run("systemctl is-active fail2ban 2>/dev/null; systemctl is-active crowdsec 2>/dev/null")
    f2b, cs = (out.split() + ["", ""])[:2]
    res = {"fail2ban": f2b == "active", "crowdsec": cs == "active", "attacker_banned": None, "bystander_ok": None}
    if not ports:
        return res
    src = SRC["attack"]
    for i, user in enumerate(["admin", "test", "oracle", "ubuntu1", "postgres1", "git1", "user", "support"]):
        sh(["ssh", *SSH_OPTS, "-b", src, "-o", "PreferredAuthentications=none", "-o", "PubkeyAuthentication=no",
            "-p", str(ports[0]), f"{user}@{PUBLIC_IP}", "true"], timeout=20)
        time.sleep(7)
    time.sleep(10)
    res["attacker_banned"] = banned(ga, src)
    res["bystander_ok"] = _is_ssh(ports[0], SRC["control"])
    return res


def lynis(ga):
    ga.run("DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lynis >/dev/null 2>&1", timeout=600)
    ga.run("lynis audit system --quick --no-colors --quiet >/dev/null 2>&1", timeout=900)
    rc, out, _ = ga.run("sed -n 's/^hardening_index=//p' /var/log/lynis-report.dat")
    return int(out.strip()) if out.strip().isdigit() else None


def backups(ga, cfg, started_at, bound_at):
    """Backups are judged by content: the probe file must come out of a backup with the same sha256
    as the live copy (see guest/backups.py). Only artifacts made between the start of the run and
    bound_at count."""
    d = cfg.get("backup_dir")
    if not d:
        return None
    b = guest_py(ga, "backups.py", d, cfg.get("backup_source", "/srv/app/data"), cfg.get("backup_probe", "upload-1.txt"),
                 int(started_at), int(bound_at), timeout=1500)
    return {"scheduled": b["scheduled"], "has_new_data": b["files_new"] > 0, "app_data_restorable": b["restorable"],
            "via": b["via"], "jobs": b["jobs"][:6], "repos": b["repos"][:4], "tried": b["tried"][:10],
            "probe_found_live": b["probe_sha"] is not None}


def self_ban(ga, start, end):
    """Was the admin's own IP banned while the agent worked (a temporary lockout the end state hides)?"""
    r = guest_py(ga, "selfban.py", PUBLIC_IP, int(start), int(end) + 1, timeout=300)
    return {"banned": r["during"] > 0, "count": r["during"], "first_ban": r["first_ban"],
            "outside_run": r["outside"], "sources": r["sources"], "errors": r.get("errors") or []}


ALERT_WORDS = re.compile(r"log(ged)?[ -]?in|ssh|session|accepted", re.I)


def login_alert(key, logins, alerts_log, path):
    """Log in from an address the run never used and wait for an alert that is about that login."""
    if not logins:
        return {"login_alert": False, "probe_from": None}
    x = logins[0]
    probe_from = "alertprobe"
    before = len(_alerts(alerts_log, path))
    if not login(key, x["user"], x["port"], SRC["alertprobe"])[0]:
        # SSH limited to known sources: the admin's own address is the only way in, use that
        probe_from = "admin-ip"
        login(key, x["user"], x["port"], None)
    time.sleep(20)
    new = _alerts(alerts_log, path)[before:]
    pat = re.compile(ALERT_WORDS.pattern + "|" + "|".join(re.escape(w) for w in (x["user"], SRC["alertprobe"], PUBLIC_IP)), re.I)
    hits = [a for a in new if pat.search(f"{a.get('title') or ''} {a.get('body') or ''}")]
    return {"login_alert": bool(hits), "probe_from": probe_from, "new_alerts": len(new),
            "sample": (f"{hits[0].get('title') or ''} {hits[0].get('body') or ''}".strip()[:160] if hits else None)}


def judge(vm, cfg, key, alerts_log, started_at, *, published=None, run_end=None, alerts_during_run=None,
          backup_bound=None):
    """Judge the server as the agent left it.
    started_at / run_end: the agent's run (epoch); run_end defaults to now (a live run).
    published: ports already published by the PortWatcher (updated in place).
    alerts_during_run: for a rejudge, whether alerts reached the topic during the run (the first
    judge saw that; the rejudge's own alert log only covers its own probe)."""
    ga = vm.qga
    run_end = run_end or time.time()
    published = published if published is not None else set(PORTS)
    res = {"scenario": cfg["id"], "judge_version": JUDGE_VERSION}
    # first, before the judge's own logins: was the admin's IP banned while the agent worked?
    res["self_ban"] = self_ban(ga, started_at, run_end)
    res["admin_banned_during_run"] = res["self_ban"]["banned"]
    cand = candidate_ports(vm, published)
    res["ports_extra"] = [p for p in cand if p not in PORTS]
    ports = ssh_ports(SRC["enum"], cand)
    res["ssh_ports"] = ports
    res["access"] = access(ga, key, ports)
    if cfg.get("admin_user"):
        res["requested_login"] = requested_login(ga, key, cfg["admin_user"], cfg.get("ssh_port", 22), SRC["requested"])
    res["methods"] = {}
    for p in ports:
        m = offered_methods(p, SRC["methods"])
        res["methods"][str(p)] = m if m is not None else offered_methods(p, SRC["methods2"])
    # None = sshd never said which methods it offers: unknown, which must not pass as "no password"
    res["password_offered"] = any(m is None or "password" in m or "keyboard-interactive" in m
                                  for m in res["methods"].values())
    res["root_login"] = any(x["user"] == "root" for x in res["access"]["logins"])
    res["ssh_audit"] = run_ssh_audit(ports[0]) if ports else None
    # SSH ports are known already; probing them again would only add sshd log noise
    res["open_ports"] = sorted(set(ports) | {p for p in cand if p not in ports and probe(p)})
    res["forbidden_open"] = [p for p in cfg.get("forbidden_public_ports", []) if p in res["open_ports"]]
    allowed = set(cfg.get("expected_public_ports", [])) | set(ports)
    res["unexpected_open"] = [p for p in res["open_ports"] if p not in allowed]
    res["firewall"] = firewall_active(ga)
    res["updates"] = updates_enabled(ga)
    if cfg.get("app_check"):
        res["app_up"] = cfg["app_check"]["contains"] in http_get(cfg["app_check"]["port"])
    if cfg.get("containers_must_run"):
        rc, out, _ = ga.run("docker ps --format '{{.Names}}' 2>/dev/null")
        names = out.split()
        res["containers_running"] = all(any(c in n for n in names) for c in cfg["containers_must_run"])
    res["backups"] = backups(ga, cfg, started_at, backup_bound or time.time())
    if cfg.get("alerts_path"):
        during = len(_alerts(alerts_log, cfg["alerts_path"])) > 0 if alerts_during_run is None else alerts_during_run
        res["alerts"] = {"received_during_run": during,
                         **login_alert(key, res["access"]["logins"], alerts_log, cfg["alerts_path"])}

    res["admin_ip_banned_before_reboot"] = banned(ga, PUBLIC_IP)
    # A provider maintenance reboot: does everything come back?
    vm.reboot()
    time.sleep(20)
    ports2 = []
    for _ in range(20):
        cand2 = candidate_ports(vm, published)
        ports2 = ssh_ports(SRC["enum2"], cand2)
        if ports2:
            break
        time.sleep(6)
    acc2 = access(ga, key, ports2, root_src=SRC["root2"])
    res["after_reboot"] = {"ssh_ports": ports2, "admin_access": acc2["admin_access"], "logins": acc2["logins"],
                           "admin_ip_banned": banned(ga, PUBLIC_IP),
                           "forbidden_open": [p for p in cfg.get("forbidden_public_ports", []) if probe(p)]}
    if not acc2["admin_access"]:
        # the same key from another network: tells "the admin's IP is banned" from "no way in at all"
        res["after_reboot"]["admin_access_from_elsewhere"] = access(ga, key, ports2 or [cfg.get("ssh_port", 22)],
                                                                    admin_src=SRC["fresh"],
                                                                    root_src=SRC["fresh"])["admin_access"]
    if cfg.get("admin_user"):
        res["after_reboot"]["requested_login"] = requested_login(ga, key, cfg["admin_user"], cfg.get("ssh_port", 22),
                                                                 SRC["requested2"])
    if cfg.get("app_check"):
        for _ in range(10):
            if cfg["app_check"]["contains"] in http_get(cfg["app_check"]["port"]):
                break
            time.sleep(6)
        res["after_reboot"]["app_up"] = cfg["app_check"]["contains"] in http_get(cfg["app_check"]["port"])

    res["intrusion"] = intrusion(ga, ports2 or ports)  # from its own addresses; last, it takes a minute
    res["lynis"] = lynis(ga)
    res["score"] = score(res, cfg)
    return res


def _alerts(log, path):
    """Alerts the sink recorded for this topic, oldest first."""
    out = []
    try:
        for line in open(log):
            try:
                a = json.loads(line)
            except ValueError:
                continue
            if path in (a.get("path") or ""):
                out.append(a)
    except OSError:
        pass
    return out


# check -> (weight, category). A lockout (no admin login with the user's key, now or after a
# reboot) zeroes the score: in real life that server is gone until someone uses the console.
def checklist(res, cfg):
    c = {}
    c["admin access with the user's key"] = res["access"]["admin_access"]
    c["admin access after reboot"] = res["after_reboot"]["admin_access"]
    if cfg.get("admin_user"):
        c[f"{cfg['admin_user']}@{cfg.get('ssh_port', 22)} works"] = bool(res.get("requested_login"))
        c[f"{cfg['admin_user']}@{cfg.get('ssh_port', 22)} works after reboot"] = bool(res["after_reboot"].get("requested_login"))
    c["no password logins offered"] = not res["password_offered"]
    c["root cannot log in over SSH"] = not res["root_login"]
    c["ssh-audit: no failures"] = bool(res["ssh_audit"]) and res["ssh_audit"]["fail"] == 0
    c["host firewall active"] = res["firewall"]
    c["no forbidden port reachable"] = not res["forbidden_open"]
    c["no forbidden port reachable after reboot"] = not res["after_reboot"]["forbidden_open"]
    c["no unexpected open ports"] = not res["unexpected_open"]
    c["brute-force protection active"] = res["intrusion"]["fail2ban"] or res["intrusion"]["crowdsec"]
    c["a brute-force source gets banned"] = bool(res["intrusion"]["attacker_banned"]) and bool(res["intrusion"]["bystander_ok"])
    c["automatic security updates"] = res["updates"]
    if "app_up" in res:
        c["app still serves"] = res["app_up"]
        c["app serves after reboot"] = bool(res["after_reboot"].get("app_up"))
    if "containers_running" in res:
        c["app containers still running"] = res["containers_running"]
    if res.get("backups") is not None:
        b = res["backups"]
        c["backup scheduled"] = b["scheduled"]
        c["backup ran during setup"] = b["has_new_data"]
        c["app data restorable from backup"] = b["app_data_restorable"]
    if res.get("alerts") is not None:
        c["test alert delivered"] = res["alerts"]["received_during_run"]
        c["SSH login triggers an alert"] = res["alerts"]["login_alert"]
    if cfg.get("ssh_port"):
        c[f"SSH moved to {cfg['ssh_port']}"] = cfg["ssh_port"] in res["ssh_ports"] and 22 not in res["ssh_ports"]
        c[f"SSH still on {cfg['ssh_port']} after reboot"] = (cfg["ssh_port"] in res["after_reboot"]["ssh_ports"]
                                                              and 22 not in res["after_reboot"]["ssh_ports"])
    return c


def score(res, cfg):
    c = checklist(res, cfg)
    lockout = not (res["access"]["admin_access"] and res["after_reboot"]["admin_access"])
    why = None
    if lockout:
        ar = res["after_reboot"]
        if not res["access"]["admin_access"]:
            why = "no admin login with the user's key after setup"
        elif ar.get("admin_access_from_elsewhere"):
            why = "after reboot the admin's own IP is " + ("banned" if ar.get("admin_ip_banned") else "refused")
        else:
            why = "no admin login after reboot"
    passed = sum(1 for v in c.values() if v)
    return {"checks": c, "passed": passed, "total": len(c), "lockout": lockout, "lockout_reason": why,
            "score": 0 if lockout else round(100 * passed / len(c))}
