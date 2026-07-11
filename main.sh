cat << 'EOF_MAIN' > /usr/bin/mtunnel
#!/bin/bash
# --- MDesign Master Core | Central Dashboard v4.1.0 (WaterWall Integration) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_main_header() {
    local s_ip=$(get_local_ip)
    
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_wg="○"; local c_wg="${DIM}"; ([ -f "/etc/wireguard/wg0.conf" ] || ip link show wg0 >/dev/null 2>&1) && { st_wg="●"; c_wg="${G}"; }
    local st_ww="○"; local c_ww="${DIM}"; [ -n "$(ls -A /etc/mwall/tunnels/*.conf 2>/dev/null)" ] && { st_ww="●"; c_ww="${G}"; }
    local st_hap="○"; local c_hap="${DIM}"; pgrep -x "haproxy" >/dev/null 2>&1 && { st_hap="●"; c_hap="${G}"; }
    local st_gost="○"; local c_gost="${DIM}"; pgrep -x "gost" >/dev/null 2>&1 && { st_gost="●"; c_gost="${G}"; }
    local st_frp="○"; local c_frp="${DIM}"; pgrep -f "frp[sc]" >/dev/null 2>&1 && { st_frp="●"; c_frp="${G}"; }

    clear; echo ""
    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MDesign Master Core v4.1${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${s_ip}${NC}                                                     ${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub:  GRE:${NC}${c_gre}${st_gre}${NC}${DIM}  VXLAN:${NC}${c_vx}${st_vx}${NC}${DIM}  WireGuard:${NC}${c_wg}${st_wg}${NC}${DIM}  WaterWall:${NC}${c_ww}${st_ww}${NC}${DIM}  │  HAProxy:${NC}${c_hap}${st_hap}${NC}${DIM}  Gost:${NC}${c_gost}${st_gost}${NC}${DIM}  FRP:${NC}${c_frp}${st_frp}${NC}    ${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ TUNNEL INFRASTRUCTURE HUB ]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}      ${DIM}[Layer 3 Routing]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}    ${DIM}[Layer 2 Bridge]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}WireGuard Crypto Matrix (Mwire)${NC}      ${DIM}[High-Speed VPN]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}WaterWall Stealth Engine (Mwall)${NC}     ${DIM}[Anti-DPI L3 Tunnel]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}FRP Reverse Proxy Engine (Mfrp)${NC}      ${DIM}[NAT Bypass Tunnel]${NC}\n  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) m_call="mgre" ;; 2) m_call="mxlan" ;; 3) m_call="mwire" ;; 4) m_call="mwall" ;; 5) m_call="mfrp" ;; 0) break ;;
        esac
        [ -n "$m_call" ] && { [ -f "/usr/bin/$m_call" ] && $m_call || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5); unset m_call; }
    done
}

while true; do
    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ CORE NETWORK & ROUTING ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub${NC} ${DIM}(GRE / VXLAN / WG / WW / FRP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover${NC} ${DIM}(Mporter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC} ${DIM}(Minterface)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY & ANALYTICS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing Shield${NC} ${DIM}(Mshield)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC} ${DIM}(Mstats & Mweb)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC} ${DIM}(Mhealer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics Tools${NC} ${DIM}(Mdiag)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${R}Nuclear Wipe${NC}         ${DIM}(Delete ALL Tunnels & Traces)${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}\n"
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;;
        2) mporter ;; 3) minterface ;; 4) mshield ;; 5) mstats ;; 6) mhealer ;; 7) mdiag ;;
        10)
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL infrastructure traces? (y/n): ${NC}"; read del_confirm
           if [[ "$del_confirm" == "y" ]]; then
               systemctl stop mgre.service mporter.service haproxy gost wg-quick@wg0 mxlan.service mweb.service mstats-web.service frps frpc 2>/dev/null
               systemctl stop mwall@* 2>/dev/null
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /etc/gost /etc/wireguard /etc/mweb /etc/frp /etc/mwall /usr/bin/m* /usr/local/bin/frp* /usr/local/bin/waterwall
               echo -e "  ${G}● Purge complete. System is vanilla.${NC}\n"; exit 0
           fi ;;
        0) clear; exit 0 ;;
    esac
done
EOF_MAIN
chmod +x /usr/bin/mtunnel
