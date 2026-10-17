#!/usr/bin/env bash
# Build a consistent MTunnel release: VERSION marker, SHA256SUMS manifest and ZIP.
# Usage: bash release/make-release.sh [OUTDIR] [--no-tests]
#   VERSION    -> written into the repo root (publish it next to main.sh on GitHub and the mirror)
#   SHA256SUMS -> written to OUTDIR only. Publish it through a SEPARATE channel; servers that want
#                 pinned downloads install it as /etc/mtunnel/trusted.sha256 (root, 0600) and set
#                 MTUNNEL_TRUSTED_SHA256_FILE. A manifest served by the same mirror is not a trust anchor.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
out="$PWD"; run_tests=1
for a in "$@"; do case "$a" in --no-tests) run_tests=0;; *) out=$(mkdir -p "$a" && cd "$a" && pwd -P);; esac; done
cd "$repo"
ver=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' core/common.sh)
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Bad core version: '$ver'" >&2; exit 1; }
files=(main.sh install.sh mporter.sh core/common.sh tunnels/mgre.sh tunnels/mxlan.sh tunnels/mrathole.sh tunnels/mbackhaul.sh tunnels/mpaqet.sh)
for f in "${files[@]}"; do
    bash -n "$f"
    case "$f" in core/common.sh) continue;; esac
    v=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$f")
    [ "$v" = "$ver" ] || { echo "Version mismatch: $f is '$v', core is '$ver'" >&2; exit 1; }
done
if [ "$run_tests" = 1 ]; then
    shopt -s nullglob
    tests=(tests/test_*.sh)
    if [ "${#tests[@]}" -gt 0 ]; then
        for t in "${tests[@]}"; do bash "$t" >/dev/null || { echo "Test failed: $t" >&2; exit 1; }; done
    else
        echo 'No tests/test_*.sh found; syntax/version validation completed.' >&2
    fi
    shopt -u nullglob
fi
printf '%s\n' "$ver" > VERSION
: > "$out/SHA256SUMS"
for f in "${files[@]}" VERSION; do printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")" >> "$out/SHA256SUMS"; done
[ -z "$(cut -d' ' -f3 "$out/SHA256SUMS" | sort | uniq -d)" ] || { echo 'Duplicate basenames in manifest' >&2; exit 1; }
zipf="$out/MTunnel-v${ver//./_}.zip"; rm -f "$zipf"
if command -v zip >/dev/null 2>&1; then zip -qr "$zipf" . -x '*.stage.*' '*.rollback.*' '.git/*'
else python3 -c 'import sys,zipfile,os
z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED)
for r,_,fs in os.walk("."):
    for f in fs: z.write(os.path.join(r,f))' "$zipf"; fi
echo "Release v$ver"; echo "  zip : $zipf"; echo "  sums: $out/SHA256SUMS"
