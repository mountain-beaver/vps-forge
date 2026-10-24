#!/usr/bin/env bash
# Run the container test suites locally, the same way CI does, with podman or docker.
#
#   tests/in-container.sh                       # every suite on every supported distro
#   tests/in-container.sh debian:13             # every suite on one distro
#   tests/in-container.sh ubuntu:24.04 audit    # one suite: checks | templates | audit
#
# The repository is mounted read-only; nothing on the host is modified.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGES=(debian:12 debian:13 ubuntu:22.04 ubuntu:24.04)
SUITES=(checks templates audit)
[[ $# -ge 1 && -n "$1" && "$1" != all ]] && IMAGES=("$1")
[[ $# -ge 2 ]] && SUITES=("$2")

if command -v podman >/dev/null; then ENGINE=podman
elif command -v docker >/dev/null; then ENGINE=docker
else echo "need podman or docker" >&2; exit 2; fi

run() { # image suite
  local cmd
  case "$2" in
    # tests/run.sh is the repo-wide lint suite; run it once as root so the deadman test runs.
    checks)    cmd='apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq shellcheck python3-yaml >/dev/null && bash tests/run.sh' ;;
    templates) cmd='bash tests/templates.sh' ;;
    audit)     cmd='bash tests/audit-scenarios.sh' ;;
    *) echo "unknown suite: $2 (checks | templates | audit)" >&2; return 2 ;;
  esac
  echo "### $2 on $1"
  "$ENGINE" run --rm -e VPS_FORGE_DISPOSABLE=1 -v "$PWD:/src:ro" -w /src "docker.io/library/$1" bash -c "$cmd"
}

failed=()
for img in "${IMAGES[@]}"; do
  for s in "${SUITES[@]}"; do
    # The lint suite doesn't depend on the distro; run it on one image only.
    [[ "$s" == checks && ${#IMAGES[@]} -gt 1 && "$img" != ubuntu:24.04 ]] && continue
    run "$img" "$s" || failed+=("$s@$img")
  done
done

echo
if ((${#failed[@]})); then echo "FAILED: ${failed[*]}"; exit 1; fi
echo "all container suites passed"
