#!/usr/bin/env bash
# Local + CI checks for vps-forge. Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SKILL=skills/vps-forge
fail=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

# Keep this file bash 3.2 clean too: the macOS job runs only this function.
external_check_tests() {
  local ext=$SKILL/scripts/external-check.sh stub out rc mode want log
  stub=$(mktemp -d); out=$(mktemp)
  cat > "$stub/ssh" <<'STUB'
#!/bin/sh
if [ -n "${STUB_LOG:-}" ]; then printf 'ssh'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; fi >> "${STUB_LOG:-/dev/null}"
case "$*" in *vpsforge-ok*) printf 'vpsforge-ok\n'; exit 0 ;; esac
case "${STUB_SSH:-publickey}" in
  password) printf 'probe@example.com: Permission denied (publickey,password).\n' >&2 ;;
  timeout) printf 'ssh: connect to host example.com port 22: Connection timed out\n' >&2 ;;
  *) printf 'probe@example.com: Permission denied (publickey).\n' >&2 ;;
esac
exit 255
STUB
  cat > "$stub/curl" <<'STUB'
#!/bin/sh
url= headers=0
for a in "$@"; do
  case "$a" in
    -I|-D) headers=1 ;;
    http://*|https://*) url=$a ;;
  esac
done
if [ "${STUB_CURL:-}" = down ]; then
  printf 'curl: (7) Failed to connect to example.com port 443\n' >&2; exit 7
fi
if [ "$headers" = 1 ]; then
  printf 'HTTP/2 200\nstrict-transport-security: max-age=31536000\nx-content-type-options: nosniff\nreferrer-policy: no-referrer\ncontent-security-policy: default-src self\nserver: caddy\n'
else
  case "${STUB_CURL:-redirect}" in
    redirect) printf '301 https://example.com/' ;;
    method) printf '405 ' ;;
    *) printf '200 ' ;;
  esac
fi
STUB
  # openssl: -tls1/-tls1_1 answers are REAL OpenSSL 3.6.5 s_client output, captured from a local
  # `openssl s_server`: refused.txt (server with -min_protocol TLSv1.2, which still prints
  # "Protocol : TLSv1" and "Cipher : 0000") and accepted.txt (a real TLS 1.0 handshake).
  cat > "$stub/openssl" <<'STUB'
#!/bin/sh
if [ "$1" = s_client ]; then
  case "$*" in
    *-help*) printf '%s\n' ' -tls1                      Just use TLSv1' ' -tls1_1                    Just use TLSv1.1' ' -tls1_2                    Just use TLSv1.2'; exit 0 ;;
    *-tls1*|*-tls1_1*) cat "$STUB_FIXTURES/${STUB_TLS:-refused}.txt"; exit 0 ;;
  esac
  printf '%s\n' '-----BEGIN CERTIFICATE-----' stub '-----END CERTIFICATE-----'
  exit 0
fi
if [ "$1" = x509 ]; then
  case "$*" in
    *-enddate*) printf 'notAfter=Jan  1 00:00:00 2030 GMT\n' ;;
    *-checkend*) [ "${STUB_OPENSSL:-valid}" = expired ] && exit 1; exit 0 ;;
    *) cat ;;
  esac
  exit 0
fi
exit 0
STUB
  cat > "$stub/nmap" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'nmap %s\n' "$*" >> "$STUB_LOG"
case "${STUB_NMAP:-ok}" in
  zero) printf '# Nmap done: 0 IP addresses (0 hosts up) scanned in 0.10 seconds\n'; exit 0 ;;
esac
case " $* " in
  *" -6 "*) printf 'Host: 2001:db8::1 ()\tPorts: %s\n# Nmap done: 1 IP address (1 host up) scanned in 0.10 seconds\n' "${STUB_NMAP6_PORTS:-22/open/tcp//ssh///}" ;;
  *) printf 'Host: 192.0.2.1 ()\tPorts: %s\n# Nmap done: 1 IP address (1 host up) scanned in 0.10 seconds\n' "${STUB_NMAP4_PORTS:-22/open/tcp//ssh///}" ;;
esac
STUB
  # No real DNS in the tests: AAAA records exist only when STUB_AAAA=1. Like glibc, getent
  # answers v4-only names with ::ffff:-mapped addresses, which must not count as IPv6.
  cat > "$stub/getent" <<'STUB'
#!/bin/sh
[ "$1" = ahostsv6 ] || exit 2
if [ "${STUB_AAAA:-}" = 1 ]; then printf '2001:db8::1      STREAM %s\n' "$2"; else printf '::ffff:192.0.2.1   STREAM %s\n' "$2"; fi
STUB
  cat > "$stub/timeout" <<'STUB'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf 'timeout %s\n' "$*" >> "$STUB_LOG"
shift; exec "$@"
STUB
  chmod +x "$stub/ssh" "$stub/curl" "$stub/openssl" "$stub/nmap" "$stub/getent" "$stub/timeout"
  export STUB_FIXTURES="$PWD/tests/fixtures"

  STUB_SSH=password PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -q 'FAIL  server offers password-style auth' "$out"; then
    ok "external-check: password auth is a FAIL"
  else
    bad "external-check: password auth (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi

  STUB_SSH=publickey PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && grep -q 'PASS  only key-based auth offered' "$out"; then
    ok "external-check: publickey-only auth is a PASS"
  else
    bad "external-check: publickey auth (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi

  STUB_SSH=timeout PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -q 'FAIL  could not verify auth methods for vpsforge-probe-.*connect-time failure' "$out"; then
    ok "external-check: an unreachable SSH probe is a FAIL (unverified, not key-only)"
  else
    bad "external-check: SSH timeout (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi

  # The legitimate admin login must run before the scan and the failing probes: they can trip
  # ufw's rate limit or PerSourcePenalties and make a working login fail.
  log=$(mktemp)
  STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --user admin --root-test >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && grep -q 'PASS  admin login as admin works' "$out" \
     && head -n 1 "$log" | grep -qF '[admin@example.com] [echo vpsforge-ok' && grep -q '^nmap ' "$log" \
     && [ "$(grep -cE 'vpsforge-probe-|root@' "$log")" -ge 2 ]; then
    ok "external-check: the admin login runs before the scan and the failing probes"
  else
    bad "external-check: probe order (rc=$rc): $(head -n 1 "$log") / $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi
  rm -f "$log"

  for mode in redirect plain method; do
    case "$mode" in
      redirect) want='PASS  http redirects to https (301)' ;;
      plain) want='WARN  http answers 200 without redirecting to https' ;;
      method) want='WARN  http answers 405 without redirecting to https' ;;
    esac
    STUB_CURL=$mode PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --domain example.com >"$out" 2>&1 && rc=0 || rc=$?
    if [[ $rc -eq 0 ]] && grep -q "$want" "$out"; then
      ok "external-check: HTTP $mode"
    else
      bad "external-check: HTTP $mode (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
    fi
  done

  STUB_CURL=down PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --domain example.com >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -q 'FAIL  https://example.com not reachable' "$out"; then
    ok "external-check: an unreachable https site is a FAIL"
  else
    bad "external-check: https down (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi

  STUB_CURL=redirect STUB_OPENSSL=expired PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --domain example.com >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -q 'FAIL  certificate expires within 14 days' "$out"; then
    ok "external-check: an expiring certificate is a FAIL"
  else
    bad "external-check: expired certificate (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi

  # TLS legacy detection: the verdict comes from real s_client transcripts. A TLS 1.2-only server
  # still makes OpenSSL print "Protocol : TLSv1" and "Cipher : 0000"; that is a refusal.
  log=$(mktemp)
  STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --domain example.com >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && grep -q 'PASS  tls1 refused by the server' "$out" && grep -q 'PASS  tls1_1 refused by the server' "$out" \
     && ! grep -q 'accepted' "$out"; then
    ok "external-check: a refused legacy TLS handshake (real OpenSSL transcript) is a PASS"
  else
    bad "external-check: TLS refusal (rc=$rc): $(grep -E 'tls1|WARN' "$out" | head -n 2 | tr '\n' '|')"
  fi
  if grep -q '^timeout 10 openssl s_client' "$log"; then
    ok "external-check: s_client runs under timeout 10"
  else
    bad "external-check: s_client is not wrapped in timeout: $(grep -c . "$log") log lines"
  fi
  STUB_TLS=accepted PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --domain example.com >"$out" 2>&1 && rc=0 || rc=$?
  if grep -q 'WARN  legacy tls1 accepted (ECDHE-RSA-AES256-SHA)' "$out"; then
    ok "external-check: an accepted legacy TLS handshake (real OpenSSL transcript) is a WARN"
  else
    bad "external-check: TLS acceptance (rc=$rc): $(grep -E 'tls1' "$out" | head -n 2 | tr '\n' '|')"
  fi
  : > "$log"
  STUB_CURL=down STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --domain example.com >"$out" 2>&1 && rc=0 || rc=$?
  if ! grep -q 's_client' "$log" && grep -q 'checks skipped' "$out" && ! grep -qE 'legacy tls1|refused by the server|certificate valid' "$out"; then
    ok "external-check: the TLS block is skipped when https is unreachable"
  else
    bad "external-check: TLS probes ran against an unreachable https site"
  fi
  rm -f "$log"

  # Port scan: 0 hosts up is a failed scan, an IPv6 literal gets -6, a name with AAAA gets a second pass.
  STUB_NMAP=zero PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-login-tests >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -q 'FAIL  port scan failed' "$out"; then
    ok "external-check: nmap with 0 hosts up is a FAIL"
  else
    bad "external-check: nmap 0 hosts (rc=$rc): $(grep -m1 -E 'FAIL|WARN' "$out" || true)"
  fi
  log=$(mktemp)
  STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" 2001:db8::1 --no-login-tests >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && [ "$(grep -c '^nmap ' "$log")" -eq 2 ] && ! grep '^nmap ' "$log" | grep -qv -- ' -6 '; then
    ok "external-check: an IPv6 literal is scanned with nmap -6"
  else
    bad "external-check: IPv6 literal (rc=$rc): $(grep '^nmap ' "$log" | tr '\n' '|')"
  fi
  : > "$log"
  STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-login-tests >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && ! grep -q -- ' -6 ' "$log"; then
    ok "external-check: a v4-only name (getent answers ::ffff:) gets no IPv6 pass"
  else
    bad "external-check: v4-only name was scanned over IPv6 (rc=$rc)"
  fi
  : > "$log"
  STUB_AAAA=1 STUB_NMAP6_PORTS='5432/open/tcp//postgresql///' STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-login-tests >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -c -- ' -6 ' "$log" | grep -q '^2$' && grep -q 'open (IPv6): 5432' "$out" \
     && grep -q 'FAIL  port 5432 is reachable over IPv6' "$out"; then
    ok "external-check: a name with AAAA gets a separate IPv6 pass and a v6-only database port is a FAIL"
  else
    bad "external-check: AAAA pass (rc=$rc): $(grep -E 'IPv6|FAIL' "$out" | tr '\n' '|')"
  fi
  : > "$log"
  # IPv4 shows nothing open (VPN-only SSH) while IPv6 is wide open: must not trip set -u.
  STUB_AAAA=1 STUB_NMAP4_PORTS='' STUB_NMAP6_PORTS='5432/open/tcp//postgresql///' STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-login-tests >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -q 'FAIL  port 5432 is reachable over IPv6' "$out" && ! grep -qi 'unbound' "$out"; then
    ok "external-check: nothing open on IPv4 and a database port open on IPv6 is a FAIL, not a crash"
  else
    bad "external-check: v4 empty / v6 open (rc=$rc): $(grep -iE 'unbound|IPv6|FAIL' "$out" | head -n 3 | tr '\n' '|')"
  fi
  rm -f "$log"

  # Identity handling: no --identity means no -i and no IdentitiesOnly, even if ~/.ssh/id_ed25519
  # exists (the agent's keys must be tried too). A path with a space stays one argument.
  home=$(mktemp -d); mkdir -p "$home/.ssh" "$home/key dir"; : > "$home/.ssh/id_ed25519"; : > "$home/key dir/id"
  log=$(mktemp)
  HOME=$home STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --user admin --no-scan >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && grep -qF '[admin@example.com] [echo vpsforge-ok' "$log" \
     && ! grep -qE '\[-i\]|IdentitiesOnly' "$log"; then
    ok "external-check: without --identity ssh gets neither -i nor IdentitiesOnly"
  else
    bad "external-check: default identity (rc=$rc): $(head -n 1 "$log")"
  fi
  : > "$log"
  HOME=$home STUB_LOG=$log PATH="$stub:$PATH" "$BASH" "$ext" example.com --user admin --no-scan --identity "$home/key dir/id" >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && grep -qF "[-i] [$home/key dir/id]" "$log" && grep -qF '[IdentitiesOnly=yes]' "$log"; then
    ok "external-check: an identity path with a space is passed as one argument"
  else
    bad "external-check: identity with a space (rc=$rc): $(head -n 1 "$log")"
  fi
  rm -rf "$home" "$log"

  # ssh-audit exit codes (3.x): 0 good, 1 connection error, 2 warnings, 3 failures.
  cat > "$stub/ssh-audit" <<'STUB'
#!/bin/sh
case "$*" in *--help*) echo '  --skip-rate-test'; exit 0 ;; esac
echo '(kex) diffie-hellman-group1-sha1 -- [fail] removed'; echo '(enc) aes128-cbc -- [warn] weak'
exit "${STUB_SA_RC:-0}"
STUB
  chmod +x "$stub/ssh-audit"
  for want in '0|PASS  ssh-audit: no warnings' '1|WARN  ssh-audit could not connect' '2|WARN  ssh-audit: 1 warning' '3|FAIL  ssh-audit: 1 failure'; do
    STUB_SA_RC=${want%%|*} PATH="$stub:$PATH" "$BASH" "$ext" example.com --no-scan --no-login-tests --ssh-audit >"$out" 2>&1 && rc=0 || rc=$?
    if grep -q "${want#*|}" "$out"; then
      ok "external-check: ssh-audit exit ${want%%|*} -> ${want#*|}"
    else
      bad "external-check: ssh-audit exit ${want%%|*} (rc=$rc): $(grep -m1 -E 'PASS|FAIL|WARN' "$out" || true)"
    fi
  done
  rm -f "$stub/ssh-audit"

  "$BASH" "$ext" --help >"$out" 2>&1 && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && grep -q 'Usage:' "$out" && ! grep -qi 'unbound variable' "$out"; then
    ok "external-check: --help works under set -u"
  else
    bad "external-check: --help (rc=$rc)"
  fi

  rm -rf "$stub" "$out"
}

if [[ "${VPS_FORGE_EXTERNAL_ONLY:-0}" == 1 ]]; then
  echo "== external-check verdicts (bash $BASH_VERSION)"
  external_check_tests
  echo
  if (( fail )); then echo "SOME CHECKS FAILED"; exit 1; fi
  echo "ALL CHECKS PASSED"; exit 0
fi

echo "== shell syntax + shellcheck"
shells=()
while IFS= read -r f; do shells+=("$f"); done < <(find "$SKILL/scripts" "$SKILL/assets" tests -type f \( -name '*.sh' -o -name '60-vps-forge' -o -name '*.bashrc' \) | sort)
for f in "${shells[@]}"; do bash -n "$f" && ok "bash -n $f" || bad "bash -n $f"; done
if command -v shellcheck >/dev/null; then
  shellcheck -S warning -s bash "${shells[@]}" && ok "shellcheck (${#shells[@]} files)" || bad "shellcheck"
else
  echo "  skip shellcheck not installed"
fi

echo "== external-check verdicts (stubbed ssh/curl/openssl)"
external_check_tests

echo "== JSON / YAML"
for f in .claude-plugin/marketplace.json .claude-plugin/plugin.json "$SKILL/assets/docker/daemon.json" "$SKILL"/evals/*/files/*.json; do
  python3 -m json.tool "$f" >/dev/null && ok "$f" || bad "$f"
done
python3 - "$SKILL" <<'PY' && ok "yaml + evals + SKILL.md frontmatter" || bad "yaml + evals + SKILL.md frontmatter"
import sys, os, glob, re, yaml
skill = sys.argv[1]

prompt_keys = {"schema_version", "name", "description", "tags", "plugins", "runs",
               "expected_outcome", "model", "max_turns", "timeout_seconds",
               "allowed_tools", "append_system_prompt", "env"}
grader_keys = {"name", "type", "weight", "arm", "pattern", "flags", "match", "target",
               "tool", "input_match", "min", "max", "before", "after", "path",
               "exists", "criteria", "focus", "baseline_file"}
grader_required = {"regex": ("pattern",), "tool_used": ("tool",),
                   "tool_order": ("before", "after"), "file_exists": ("path",),
                   "baseline": ("baseline_file", "criteria")}

def frontmatter(path):
    text = open(path).read()
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    assert m, f"{path} has no frontmatter"
    return yaml.safe_load(m.group(1)) or {}, m.group(2)

def check_grader(path, fm, body):
    assert isinstance(fm, dict), f"{path}: grader frontmatter is not a mapping"
    unknown = set(fm) - grader_keys
    assert not unknown, f"{path}: unknown grader keys {sorted(unknown)}"
    kind = fm.get("type")
    assert kind == "llm" or kind in grader_required, f"{path}: bad grader type {kind!r}"
    for key in grader_required.get(kind, ()):
        assert fm.get(key) not in (None, ""), f"{path}: {kind} grader needs {key}"
    if kind == "llm":
        assert fm.get("criteria") or body.strip(), f"{path}: llm grader needs criteria"

for f in glob.glob(f"{skill}/evals/*/case.yaml") + [f"{skill}/assets/cloud-init.yaml"]:
    yaml.safe_load(open(f))
for d in sorted(glob.glob(f"{skill}/evals/*")):
    if not os.path.isdir(d):
        continue
    prompt = os.path.join(d, "prompt.md")
    case_file = os.path.join(d, "case.yaml")
    if not os.path.exists(prompt) and not os.path.exists(case_file):
        continue
    case = {}
    if os.path.exists(case_file):
        case = yaml.safe_load(open(case_file)) or {}
        assert isinstance(case, dict), f"{case_file}: not a mapping"
        assert case.get("schema_version") == "1.1", f"{case_file}: schema_version must be 1.1"
        assert case.get("name"), f"{case_file}: name is required"
    if os.path.exists(prompt):
        fm, body = frontmatter(prompt)
        assert isinstance(fm, dict), f"{prompt}: frontmatter is not a mapping"
        unknown = set(fm) - prompt_keys
        assert not unknown, f"{prompt}: unknown prompt keys {sorted(unknown)}"
        assert fm.get("schema_version", "1.1") == "1.1", f"{prompt}: schema_version must be 1.1"
        assert body.strip(), f"{prompt}: the prompt is empty"
    inline = case.get("graders") or []
    assert isinstance(inline, list), f"{case_file}: graders must be a list"
    files = sorted(glob.glob(os.path.join(d, "graders", "*.md")))
    assert files or inline, f"{d}: a case needs at least one grader"
    for g in files:
        fm, body = frontmatter(g)
        check_grader(g, fm, body)
    for g in inline:
        assert isinstance(g, dict) and g.get("name"), f"{case_file}: an inline grader needs a name"
        check_grader(f"{case_file} grader {g['name']}", g, g.get("criteria", ""))
text = open(f"{skill}/SKILL.md").read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
assert m, "SKILL.md has no frontmatter"
fm = yaml.safe_load(m.group(1))
assert fm["name"] == "vps-forge", fm.get("name")
assert 50 < len(fm["description"]) <= 1024, len(fm["description"])
assert len(text.splitlines()) < 500, "SKILL.md should stay under 500 lines"
for ref in set(re.findall(r"`((?:references|scripts|assets)/[^`*{ ]+)`", text)):
    path = ref.split(" ")[0].rstrip(".,")
    if not glob.glob(f"{skill}/{path}*"):
        raise SystemExit(f"SKILL.md references missing file: {path}")
for f in glob.glob(".github/**/*.yml", recursive=True):
    yaml.safe_load(open(f))
PY
python3 - "$SKILL" <<'PY' && ok "versions agree (plugin.json, CHANGELOG, audit.sh)" || bad "version mismatch"
import json, re, sys
skill = sys.argv[1]
plugin = json.load(open(".claude-plugin/plugin.json"))["version"]
released = re.findall(r"^## (\d+\.\d+\.\d+)", open("CHANGELOG.md").read(), re.M)
audit = re.search(r'^VERSION="([^"]+)"', open(f"{skill}/scripts/audit.sh").read(), re.M).group(1)
assert released and released[0] == plugin == audit, f"plugin.json {plugin}, CHANGELOG {released[:1]}, audit.sh {audit}"
PY
if command -v claude >/dev/null; then
  claude plugin validate --strict . >/dev/null 2>&1 && ok "claude plugin validate --strict ." || bad "claude plugin validate ."
  claude plugin validate --strict .claude-plugin/plugin.json >/dev/null 2>&1 && ok "claude plugin validate --strict plugin.json" || bad "claude plugin validate plugin.json"
else
  echo "  skip claude plugin validate (Claude Code not installed)"
fi

if [[ "${VPS_FORGE_LINT_ONLY:-0}" == 1 ]]; then # lint only: no host to audit, no namespaces
  echo; if (( fail )); then echo "SOME CHECKS FAILED"; exit 1; fi; echo "LINT PASSED"; exit 0
fi

echo "== alerts / backup / cloudflare-sync scripts against stubs"
for t in alerts backup cf-sync; do
  [[ -f "tests/$t.sh" ]] || continue
  bash "tests/$t.sh" | grep -E '^(  |==)' || fail=1
done

echo "== audit.sh smoke test (read-only)"
out=$(bash "$SKILL/scripts/audit.sh" --json || true)
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["checks"]; print("  ok   audit.sh json: score", d["score"], d["counts"])' || bad "audit.sh json"

echo "== deadman snapshot/restore in a fake root"
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  bash tests/deadman.sh | sed -n '/^  /p' || fail=1
elif unshare -r true 2>/dev/null; then
  # A user namespace gives tar and chmod the root powers the test needs, without sudo.
  unshare -r bash tests/deadman.sh | sed -n '/^  /p' || fail=1
else
  echo "  skip deadman test needs root or user namespaces (run: sudo tests/run.sh)"
fi

echo
if (( fail )); then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
