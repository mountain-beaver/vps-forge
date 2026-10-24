"""QEMU VM helpers for the vps-forge benchmark.

Every VM runs inside its own network namespace (pasta), so it can publish the guest's real port
numbers (22, 80, 443, 2222, ...) on 127.0.0.1 without root and without clashing with other runs.
The judge talks to the guest through the QEMU guest agent: like a provider's console, that path
does not depend on SSH or the firewall the agent under test may have changed.
"""
import base64
import json
import os
import pathlib
import shutil
import socket
import subprocess
import time

PUBLIC_IP = "203.0.113.10"  # the VM's "public address" inside the namespace (added to lo by cell.py)
# Where connections come from, as the guest sees them (slirp keeps non-loopback source addresses).
# The agent under test, like the user, connects from PUBLIC_IP itself: that is "the admin's IP".
# The judge's own probes that are expected to fail (wrong users, root, auth-method listing,
# ssh-audit, brute force) come from other addresses, so a correctly strict fail2ban bans those
# and never the admin. Each purpose gets its own address, so one ban cannot skew another check.
SOURCES = {
    "enum": "198.51.100.10",       # SSH banner discovery, before the reboot
    "methods": "198.51.100.11",    # which auth methods sshd offers
    "audit": "198.51.100.12",      # ssh-audit
    "root": "198.51.100.13",       # can root log in with the user's key
    "requested": "198.51.100.14",  # the scenario's requested login (may legitimately fail)
    "ports": "198.51.100.15",      # non-SSH port probes (never logged by sshd)
    "enum2": "198.51.100.20",      # SSH banner discovery, after the reboot
    "methods2": "198.51.100.21",
    "root2": "198.51.100.23",
    "requested2": "198.51.100.24",
    "fresh": "198.51.100.30",      # the admin from another network (tells "admin IP banned" apart)
    "alertprobe": "198.51.100.40", # a successful login from a new address: must raise an alert
    "attack": "192.0.2.66",        # brute-force source
    "control": "192.0.2.77",       # a bystander during the brute force: must not be blocked
}
# A rejudge boots a disk that the first judge already probed: a long or incremental bantime may
# still hold that judge's addresses. The rejudge uses its own set, so old bans cannot skew it.
SOURCES_REJUDGE = {k: v.replace("198.51.100.", "198.51.100.1").replace("192.0.2.", "192.0.2.1")
                   for k, v in SOURCES.items()}
# Guest ports published on PUBLIC_IP inside the namespace (same numbers on both sides). Ports the
# agent opens later are added on the fly through the QEMU monitor (see PortWatcher in cell.py).
PORTS = [22, 80, 443, 2222, 2200, 2022, 22022, 3000, 3306, 5000, 5432, 6379, 8000, 8080, 8081,
         8443, 9000, 9090, 9100, 9443, 10000, 11211, 27017]
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", "ControlPath=none", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8"]


def sh(cmd, **kw):
    try:
        return subprocess.run(cmd, text=True, capture_output=True, **kw)
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return subprocess.CompletedProcess(cmd, 124, out, "timeout")


class GuestAgent:
    def __init__(self, path):
        self.path = str(path)

    def _call(self, payload, timeout=30):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.path)
        try:
            sync_id = int(time.time() * 1000) % 2**31
            s.sendall(json.dumps({"execute": "guest-sync", "arguments": {"id": sync_id}}).encode() + b"\n")
            buf = b""
            while True:  # skip stale replies until our sync id comes back
                buf += s.recv(65536)
                lines = buf.split(b"\n")
                buf = lines[-1]
                if any(json.loads(l).get("return") == sync_id for l in lines[:-1] if l.strip()):
                    break
            s.sendall(json.dumps(payload).encode() + b"\n")
            while b"\n" not in buf:
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
            return json.loads(buf.split(b"\n")[0])
        finally:
            s.close()

    def ping(self):
        try:
            return "return" in self._call({"execute": "guest-ping"}, timeout=5)
        except OSError:
            return False

    def run(self, cmd, timeout=300):
        """Run a shell command as root in the guest. Returns (rc, stdout, stderr)."""
        r = self._call({"execute": "guest-exec", "arguments": {
            "path": "/bin/sh", "arg": ["-c", cmd], "capture-output": True}})
        if "error" in r:
            return 255, "", json.dumps(r["error"])
        pid = r["return"]["pid"]
        end = time.time() + timeout
        while time.time() < end:
            st = self._call({"execute": "guest-exec-status", "arguments": {"pid": pid}})
            ret = st.get("return", {})
            if ret.get("exited"):
                dec = lambda k: base64.b64decode(ret.get(k, "")).decode(errors="replace")
                return ret.get("exitcode", 255), dec("out-data"), dec("err-data")
            time.sleep(0.5)
        return 124, "", "timeout"


class VM:
    def __init__(self, workdir, base_image, name, memory_mb=2048, cpus=2, extra_disk_gb=0):
        self.dir = pathlib.Path(workdir)
        self.base = pathlib.Path(base_image)
        self.name = name
        self.memory_mb = memory_mb
        self.cpus = cpus
        self.extra_disk_gb = extra_disk_gb
        self.disk = self.dir / "disk.qcow2"
        self.extra = self.dir / "extra.qcow2"
        self.qga = GuestAgent(self.dir / "qga.sock")
        self.pidfile = self.dir / "qemu.pid"

    def create(self, size_gb=16, extra_base=None):
        self.dir.mkdir(parents=True, exist_ok=True)
        if extra_base:
            sh(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", str(extra_base), str(self.extra)])
        r = sh(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", str(self.base), str(self.disk), f"{size_gb}G"])
        if r.returncode:
            raise RuntimeError(r.stderr)
        if self.extra_disk_gb and not self.extra.exists():
            sh(["qemu-img", "create", "-q", "-f", "qcow2", str(self.extra), f"{self.extra_disk_gb}G"])

    def boot(self, seed_iso):
        fwd = ",".join(f"hostfwd=tcp:{PUBLIC_IP}:{p}-:{p}" for p in PORTS)
        cmd = ["qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-smp", str(self.cpus), "-m", str(self.memory_mb),
               "-audio", "none", "-display", "none", "-daemonize", "-pidfile", str(self.pidfile),
               "-serial", f"file:{self.dir / 'serial.log'}",
               "-drive", f"file={self.disk},if=virtio", "-drive", f"file={seed_iso},media=cdrom",
               "-netdev", f"user,id=n0,{fwd}", "-device", "virtio-net-pci,netdev=n0",
               "-chardev", f"socket,path={self.dir / 'qga.sock'},server=on,wait=off,id=qga0",
               "-device", "virtio-serial", "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
               "-monitor", f"unix:{self.dir / 'mon.sock'},server=on,wait=off"]
        if self.extra_disk_gb:
            cmd += ["-drive", f"file={self.extra},if=virtio"]
        r = sh(cmd)
        if r.returncode:
            raise RuntimeError(f"qemu failed: {r.stderr}")

    def pid(self):
        try:
            return int(self.pidfile.read_text().strip())
        except (OSError, ValueError):
            return None

    def alive(self):
        p = self.pid()
        if not p:
            return False
        try:
            os.kill(p, 0)
            return True
        except OSError:
            return False

    def wait_agent(self, timeout=600):
        end = time.time() + timeout
        while time.time() < end:
            if self.qga.ping():
                return True
            time.sleep(3)
        return False

    def wait_ssh(self, key, user="root", port=22, timeout=600):
        end = time.time() + timeout
        while time.time() < end:
            r = sh(["ssh", *SSH_OPTS, "-i", str(key), "-p", str(port), f"{user}@{PUBLIC_IP}", "true"], timeout=30)
            if r.returncode == 0:
                return True
            time.sleep(3)
        return False

    def shutdown(self, timeout=180):
        if not self.alive():
            return
        try:
            self.qga._call({"execute": "guest-shutdown", "arguments": {"mode": "powerdown"}}, timeout=5)
        except (OSError, ValueError):
            pass
        end = time.time() + timeout
        while time.time() < end and self.alive():
            time.sleep(2)
        self.kill()

    def kill(self):
        p = self.pid()
        if p:
            try:
                os.kill(p, 15)
            except OSError:
                pass

    def hostfwd_add(self, port):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        try:
            s.connect(str(self.dir / "mon.sock"))
            s.sendall(f"hostfwd_add n0 tcp:{PUBLIC_IP}:{port}-:{port}\n".encode())
            time.sleep(0.3)
            return True
        except OSError:
            return False
        finally:
            s.close()

    def reboot(self, timeout=600):
        """Reboot from inside (like a provider maintenance reboot) and wait for the guest agent."""
        try:
            self.qga._call({"execute": "guest-shutdown", "arguments": {"mode": "reboot"}}, timeout=5)
        except (OSError, ValueError):
            pass
        time.sleep(15)
        return self.wait_agent(timeout)


def default_user(distro):
    """The login a stock cloud image of this distro gives the key (cloud-init's default user)."""
    return distro.split("-")[0]  # debian-12 -> debian, ubuntu-24.04 -> ubuntu


def seed_iso(workdir, hostname, root_pubkey, root_password, instance_id, style="root"):
    """NoCloud seed.
    style "root": root with the user's key and a password (as many providers deliver it).
    style "stock": like a stock cloud image: root login disabled by cloud-init (disable_root), the key
    on the distro's default user (debian / ubuntu), which has passwordless sudo; no password set."""
    d = pathlib.Path(workdir) / "seed"
    d.mkdir(parents=True, exist_ok=True)
    (d / "meta-data").write_text(f"instance-id: {instance_id}\nlocal-hostname: {hostname}\n")
    if style == "stock":
        users = f"""disable_root: true
users: [default]
ssh_authorized_keys: ["{root_pubkey}"]
"""
    else:
        users = f"""disable_root: false
ssh_pwauth: true
users:
  - name: root
    ssh_authorized_keys: ["{root_pubkey}"]
chpasswd:
  expire: false
  users: [{{name: root, password: "{root_password}", type: text}}]
"""
    (d / "user-data").write_text(f"""#cloud-config
{users}package_update: true
packages: [qemu-guest-agent, curl]
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
""")
    iso = pathlib.Path(workdir) / "seed.iso"
    r = sh(["xorriso", "-as", "mkisofs", "-quiet", "-o", str(iso), "-V", "cidata", "-J", "-r", str(d)])
    if r.returncode:
        raise RuntimeError(r.stderr)
    return iso


def copy_tree(src, dst):
    if pathlib.Path(dst).exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
