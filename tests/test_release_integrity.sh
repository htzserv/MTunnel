#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ver=$(tr -d '\r\n ' < "$repo/VERSION")
[ "$ver" = 1.0.6 ]
files=(main.sh install.sh mporter.sh tunnels/mgre.sh tunnels/mxlan.sh tunnels/mrathole.sh tunnels/mbackhaul.sh tunnels/mpaqet.sh)
for f in "${files[@]}"; do
  bash -n "$repo/$f"
  got=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$repo/$f" | head -n1)
  [ "$got" = "$ver" ] || { echo "$f version $got != $ver" >&2; exit 1; }
done
bash -n "$repo/core/common.sh"
core=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\([0-9.]*\)"$/\1/p' "$repo/core/common.sh" | head -n1)
[ "$core" = "$ver" ]
# shellcheck disable=SC1090
source "$repo/core/common.sh"
mt_update_available 1.0.6 15.0.2
! mt_update_available 15.0.2 1.0.6
mt_release_migration 16.0.2 1.0.6
! mt_release_migration 1.0.6 16.0.2
