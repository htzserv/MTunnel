#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"

# Main dashboard: stable palette semantics.
grep -F '${DIM}Local:${NC} ${W}${s_ip}${NC}' "$repo/main.sh" >/dev/null
grep -F '${Y}Peer:${NC} ${Y}${peer_remote}${NC}' "$repo/main.sh" >/dev/null
grep -F '${DIM}Ping:${NC} ${Y}${t_ping:----}${NC}' "$repo/main.sh" >/dev/null
grep -F '${DIM}Up:${NC} ${W}${uptime}${NC}' "$repo/main.sh" >/dev/null

# Socket-based tunnel headers: peer is yellow, matching the stable theme.
for f in mbackhaul mrathole mpaqet; do
  grep -F '${Y}Peer:${NC} ${Y}%-24.24s${NC}' "$repo/tunnels/$f.sh" >/dev/null
done

# GRE/VXLAN route rows: local and remote endpoints are both yellow.
for f in mgre mxlan; do
  grep -F '${DIM}➔${NC} ${Y}%s${NC} ${DIM}➔${NC} ${Y}%s${NC}' "$repo/tunnels/$f.sh" >/dev/null
done

# MPorter header keeps the established multicolor palette.
grep -F '${DIM}IP:${NC} ${W}${STATS_SERVER_IP}${NC}' "$repo/mporter.sh" >/dev/null
grep -F '${DIM}Pts:${NC} ${G}${STATS_TOTAL_PORTS}${NC}' "$repo/mporter.sh" >/dev/null
grep -F '${C}%-12s${NC}' "$repo/mporter.sh" >/dev/null
grep -F '${M}%-8s${NC}' "$repo/mporter.sh" >/dev/null
grep -F '${G}%-26s${NC}' "$repo/mporter.sh" >/dev/null

echo 'Header palette regression test: PASS'
