#!/bin/bash
MODULE_VERSION="15.0.1"
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; DIM='\033[2;37m'; NC='\033[0m'
scope=all
while [ "$#" -gt 0 ]; do case "$1" in --scope) scope="${2:-all}"; shift 2;; --scan) scan_only=1; shift;; *) shift;; esac; done
units_for_scope() {
    case "$1" in
        gre) echo 'mgre.service';;
        vxlan) echo 'mxlan.service';;
        backhaul) systemctl list-unit-files 'mbackhaul@*.service' --no-legend 2>/dev/null | awk '{print $1}';;
        rathole) systemctl list-unit-files 'mrathole@*.service' --no-legend 2>/dev/null | awk '{print $1}';;
        paqet) systemctl list-unit-files 'mpaqet@*.service' --no-legend 2>/dev/null | awk '{print $1}';;
        all) echo 'mgre.service'; echo 'mxlan.service'; systemctl list-unit-files 'mbackhaul@*.service' 'mrathole@*.service' 'mpaqet@*.service' --no-legend 2>/dev/null | awk '{print $1}';;
    esac
}
scan() {
    local u bad=0
    while read -r u; do
        [ -n "$u" ] || continue
        systemctl is-enabled --quiet "$u" 2>/dev/null || continue
        if ! systemctl is-active --quiet "$u" 2>/dev/null; then
            echo -e "  ${Y}● Recovering ${u}...${NC}"
            systemctl restart "$u" 2>/dev/null || bad=1
        fi
    done < <(units_for_scope "$scope")
    return "$bad"
}
[ "${scan_only:-0}" = 1 ] && { scan; exit $?; }
while true; do
    clear 2>/dev/null || true
    echo -e "\n  ${B}┌─[ AUTO RECOVERY — ${scope^^} ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run Recovery Scan Now${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r opt || exit 0
    case "$opt" in 1) scan; echo -e "  ${G}● Recovery scan complete.${NC}"; read -r -p '  Press Enter...' _;; 0|q|Q) exit 0;; esac
done
