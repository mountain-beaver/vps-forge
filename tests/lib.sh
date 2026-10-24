# Shared helpers for the container tests (sourced, not executed).
# shellcheck shell=bash disable=SC2034  # variables are used by the sourcing scripts

SKILL=skills/vps-forge
ASSETS=$SKILL/assets
fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
note() { printf '  skip %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

# These tests overwrite files in /etc. Refuse to run anywhere but a throwaway container.
# systemd-detect-virt alone is not enough: it reports lxc/openvz on container-based VPSs,
# which are real servers. Require both an OCI container marker and an explicit opt-in that
# only tests/in-container.sh and the CI workflow set.
require_disposable_container() {
  if [[ ! -e /.dockerenv && ! -e /run/.containerenv ]]; then
    echo "refusing to run: $0 modifies /etc and must run inside a disposable podman/docker container (tests/in-container.sh)" >&2
    exit 2
  fi
  if [[ "${VPS_FORGE_DISPOSABLE:-}" != 1 ]]; then
    echo "refusing to run: VPS_FORGE_DISPOSABLE=1 is not set; start $0 through tests/in-container.sh" >&2
    exit 2
  fi
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root inside the container" >&2; exit 2; }
}

apt_install() { # pkgs... (missing packages are skipped, not fatal)
  local p avail=()
  for p in "$@"; do
    apt-cache show "$p" >/dev/null 2>&1 && avail+=("$p")
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${avail[@]}" >/dev/null
}

# Replace the template placeholders with test values. Fails if any <placeholder> survives
# outside a comment, so a new placeholder can't slip in untested.
fill() { # src dst
  sed -e 's/<you@example\.com>/admin@example.com/g' \
      -e 's/<example\.com>/example.com/g' \
      -e 's/<8080>/8080/g' \
      -e 's/<hostname>/forge-test/g' \
      -e 's/<admin>/forgeadmin/g' \
      -e 's/<admin-ip>/198.51.100.7/g' \
      -e 's/<ssh-port>/22/g' \
      -e "s|<ssh-ed25519 AAAA[^>]*>|${TEST_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test}|g" \
      "$1" > "$2"
  if grep -vE '^[[:space:]]*(#|//)' "$2" | grep -qE '<[a-z0-9@._-]+>'; then
    bad "unfilled placeholder in $1: $(grep -vE '^[[:space:]]*(#|//)' "$2" | grep -oE '<[a-z0-9@._-]+>' | sort -u | paste -sd' ' -)"
    return 1
  fi
}

# sshd needs host keys and its privilege-separation dir to run -t / -T.
prepare_sshd() {
  ssh-keygen -A >/dev/null
  install -d -m 0755 /run/sshd
  getent group sshusers >/dev/null || groupadd sshusers
}

sshd_value() { # key -> effective value from sshd -T
  /usr/sbin/sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k { $1=""; sub(/^ /,""); print; exit }'
}

finish() {
  echo
  if (( fail )); then echo "SOME CHECKS FAILED"; exit 1; fi
  echo "ALL CHECKS PASSED"
}
