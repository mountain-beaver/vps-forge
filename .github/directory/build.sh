#!/usr/bin/env bash
# Builds the plugin folder for Anthropic's plugin directory: only what gets installed.
# Reads the committed tree (git archive), without bench/, tests/, docs/ or evals.
# Usage: .github/directory/build.sh <out-dir> [<commit>]
set -euo pipefail
out=${1:?usage: build.sh <out-dir> [commit]}
rev=${2:-HEAD}
root=$(git rev-parse --show-toplevel)
cd "$root"
[[ -e "$out" ]] && { [[ -z "$(ls -A "$out")" ]] || { echo "build.sh: $out is not empty" >&2; exit 1; }; }
mkdir -p "$out"
git archive "$rev" .claude-plugin/plugin.json .claude-plugin/icon.png LICENSE skills/vps-forge | tar -x -C "$out"
rm -rf "$out/skills/vps-forge/evals"
git show "$rev:.github/directory/README.md" > "$out/README.md"
# The directory rejects symlinks, OS junk files and anything that isn't text or an image
bad=$(find "$out" -type l -o -name .DS_Store -o -name '*.zip' -o -name '*.pdf' -o -name '*.ico')
[[ -z "$bad" ]] || { echo "build.sh: not allowed in the plugin: $bad" >&2; exit 1; }
big=$(find "$out" -type f ! -name '*.png' -size +256k)
[[ -z "$big" ]] || { echo "build.sh: over 256 KiB: $big" >&2; exit 1; }
echo "$out: $(find "$out" -type f | wc -l) files from $(git rev-parse --short "$rev")"
