#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
main="$repo/main.sh"
grep -F 'mt_main_header_cell 22 "$1"' "$main" >/dev/null
grep -F 'mt_main_header_cell $((31+extra)) "$2"' "$main" >/dev/null
grep -F '${Y}Peer:${NC} ${Y}${peer_remote}${NC}' "$main" >/dev/null
grep -F '[ TUNNEL CORE & FABRIC MODULES ]' "$main" >/dev/null
grep -F '[ TOOLS & BENCHMARK UTILITIES ]' "$main" >/dev/null
grep -F '[ SYSTEM UPDATE & MAINTENANCE ]' "$main" >/dev/null
grep -F '[ SESSION CONTROL ]' "$main" >/dev/null
! grep -F 'Build tunnels, import peer links' "$main" >/dev/null
! grep -F 'Routing helpers, forwarders' "$main" >/dev/null
! grep -F 'Update engines, install bundles' "$main" >/dev/null
! grep -F 'Leave MTunnel and return' "$main" >/dev/null
