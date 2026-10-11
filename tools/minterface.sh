#!/bin/bash
MODULE_VERSION="15.0.1"
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; W='\033[1;37m'; C='\033[0;36m'; DIM='\033[2;37m'; NC='\033[0m'
scope=all
while [ "$#" -gt 0 ]; do case "$1" in --scope) scope="${2:-all}"; shift 2;; --render) shift;; *) shift;; esac; done
case "$scope" in gre) pat='^(ir_|kh_|gre|ipip|sit_)';; vxlan) pat='^(vx_|br_)';; backhaul) pat='^(bh_|lo$)';; rathole) pat='^(rat_|lo$)';; paqet) pat='^(pq_|lo$)';; *) pat='.';; esac
clear 2>/dev/null || true
echo -e "\n  ${B}┌─[ INTERFACE BLUEPRINT — ${scope^^} ]${NC}\n  ${DIM}│${NC}"
printf "  ${DIM}├─${NC} ${W}%-16s %-8s %-8s %-20s${NC}\n" "INTERFACE" "STATE" "MTU" "ADDRESS"
while IFS= read -r line; do
    name=$(awk '{print $1}' <<<"$line"); state=$(awk '{print $2}' <<<"$line"); addr=$(awk '{print $3}' <<<"$line")
    [[ "$name" =~ $pat ]] || continue
    mtu=$(cat "/sys/class/net/$name/mtu" 2>/dev/null || echo '-')
    printf "  ${DIM}├─${NC} ${C}%-16.16s${NC} %-8.8s %-8.8s %-20.20s\n" "$name" "$state" "$mtu" "${addr:--}"
done < <(ip -br addr show 2>/dev/null)
echo -e "  ${DIM}└─${NC} ${DIM}Read-only view; no interface is changed.${NC}\n"
read -r -p '  Press Enter to return...' _
