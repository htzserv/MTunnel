#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# GRE/VXLAN latency probes must be bound to the interface that owns that
# tunnel's inner address. A plain route-selected ping is ambiguous when
# several same-engine instances coexist or legacy routes overlap.
grep -F 'pcmd+=(-I "$T_NAME")' "$repo/tunnels/mgre.sh" >/dev/null
grep -F 'pcmd+=(-I "$BR_NAME")' "$repo/tunnels/mxlan.sh" >/dev/null
grep -F 'mt_ping_stats "$peer_vip" "$T_NAME"' "$repo/main.sh" >/dev/null
grep -F 'mt_ping_stats "$peer_vip" "$BR_NAME"' "$repo/main.sh" >/dev/null

# Per-instance transport peer lookup is systemd-PID scoped; no global
# "first ESTAB on this port" lookup may be used for operational status.
grep -F 'systemctl show "$unit" -p MainPID --value' "$repo/tunnels/mbackhaul.sh" >/dev/null
grep -F 'systemctl show "$unit" -p MainPID --value' "$repo/tunnels/mrathole.sh" >/dev/null
grep -F "lep=\$(awk '{print \$3}' <<< \"\$line\"); pep=\$(awk '{print \$4}' <<< \"\$line\")" "$repo/main.sh" >/dev/null
grep -F "lep=\$(awk '{print \$3}' <<< \"\$line\"); pep=\$(awk '{print \$4}' <<< \"\$line\")" "$repo/tunnels/mbackhaul.sh" >/dev/null
grep -F "lep=\$(awk '{print \$3}' <<< \"\$line\"); pep=\$(awk '{print \$4}' <<< \"\$line\")" "$repo/tunnels/mrathole.sh" >/dev/null
! grep -F 'ss -tn src ":$TUN_PORT"' "$repo/tunnels/mbackhaul.sh" >/dev/null
! grep -F 'ss -tn src ":$LINK_PORT"' "$repo/tunnels/mrathole.sh" >/dev/null

# Paqet client liveness is isolated by remote address + port and old broad
# rules are removed on apply, otherwise same-port peers cross-count traffic.
grep -F 'src_args=(-s "$remote")' "$repo/tunnels/mpaqet.sh" >/dev/null
grep -F 'mt_delete_tagged_rules iptables mangle INPUT "MPAQET_LINK_${name}"' "$repo/tunnels/mpaqet.sh" >/dev/null

# Row caches use unique staging files, so two open MTunnel shells cannot
# truncate/mix each other's header snapshots.
grep -F 'mktemp "$SECURE_TMP/.mgre_stats_cache.XXXXXX"' "$repo/tunnels/mgre.sh" >/dev/null
grep -F 'mktemp "$SECURE_TMP/.mxlan_stats_cache.XXXXXX"' "$repo/tunnels/mxlan.sh" >/dev/null
grep -F 'mktemp "$SECURE_TMP/.mbackhaul_hdr_rows.XXXXXX"' "$repo/tunnels/mbackhaul.sh" >/dev/null
grep -F 'mktemp "$SECURE_TMP/.mrathole_hdr_rows.XXXXXX"' "$repo/tunnels/mrathole.sh" >/dev/null
grep -F 'mktemp "$SECURE_TMP/.mpaqet_hdr_rows.XXXXXX"' "$repo/tunnels/mpaqet.sh" >/dev/null

# Peer color follows the established stable yellow convention in every per-tunnel row.
grep -F '${DIM}Peer:${NC} ${Y}${t_remote}${NC}' "$repo/main.sh" >/dev/null
grep -F '${DIM}Peer:${NC} ${Y}%-24.24s${NC}' "$repo/tunnels/mbackhaul.sh" >/dev/null
grep -F '${DIM}Peer:${NC} ${Y}%-24.24s${NC}' "$repo/tunnels/mrathole.sh" >/dev/null
grep -F '${DIM}Peer:${NC} ${Y}%-24.24s${NC}' "$repo/tunnels/mpaqet.sh" >/dev/null
grep -F '${DIM}➔${NC} ${Y}%s${NC}' "$repo/tunnels/mgre.sh" >/dev/null
grep -F '${DIM}➔${NC} ${Y}%s${NC}' "$repo/tunnels/mxlan.sh" >/dev/null
