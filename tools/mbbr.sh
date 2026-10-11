#!/bin/bash
MODULE_VERSION="15.0.1"
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; DIM='\033[2;37m'; NC='\033[0m'
set_state() {
    local want="$1" cc qdisc
    if [ "$want" = 1 ]; then cc=bbr; qdisc=fq; else cc=cubic; qdisc=fq_codel; fi
    if [ "$want" = 1 ]; then modprobe tcp_bbr 2>/dev/null || true; fi
    mkdir -p /etc/sysctl.d || return 1
    cat > /etc/sysctl.d/99-mtunnel-bbr.conf <<CFG
net.core.default_qdisc=$qdisc
net.ipv4.tcp_congestion_control=$cc
CFG
    sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || return 1
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "$cc" ]
}
status() { [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ] && echo ON || echo OFF; }
case "${1:-}" in
    --enable) set_state 1; exit $?;;
    --disable) set_state 0; exit $?;;
    --status) status; exit 0;;
    --from-tunnel|'')
        while true; do
            clear 2>/dev/null || true
            echo -e "\n  ${B}╭────────────────────────────────────────────────────────────╮${NC}"
            printf "  ${B}│${NC} ${W}MTunnel BBR v%s${NC} — Status: ${C}%s${NC}%*s${B}│${NC}\n" "$MODULE_VERSION" "$(status)" 21 ''
            echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}\n"
            echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable BBR${NC}"
            echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable BBR${NC}"
            echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return${NC}\n"
            echo -ne "  ${C}Select ❯❯ ${NC}"; read -r opt || exit 0
            case "$opt" in 1) set_state 1;; 2) set_state 0;; 0|q|Q) exit 0;; esac
        done;;
    *) echo "usage: mbbr [--enable|--disable|--status|--from-tunnel]" >&2; exit 2;;
esac
