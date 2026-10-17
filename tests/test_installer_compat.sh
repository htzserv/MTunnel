#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/runtime/core" "$work/root"
cp "$repo/install.sh" "$work/runtime/install.sh"
cp "$repo/core/common.sh" "$work/runtime/core/common.sh"
# Simulate an older same-API common that lacks the two helpers which previously
# caused /dev/fd/...: command not found during installation.
cat >> "$work/runtime/core/common.sh" <<'LEGACY'
unset -f mt_retired_bundle_blocked mt_confirm_downgrade
LEGACY
bash "$work/runtime/install.sh" --local "$repo" --root "$work/root" --no-launch >/dev/null
[ -x "$work/root/usr/bin/mtunnel" ]
[ -f "$work/root/usr/lib/mtunnel/common.sh" ]
[ -x "$work/root/root/mtunnel/install.sh" ]
