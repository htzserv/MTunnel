#!/bin/bash
# --- MDesign Master Core | Central Dashboard v2.2.0 (Tunnel Hub Integration) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

MTUNNEL_PATH="/usr/bin/mtunnel"
MGRE_MODULE="/usr/bin/mgre"
MXLAN_MODULE="/usr/bin/mxlan"
MWIRE_MODULE="/usr/bin/mwire"
MPORTER_MODULE="/usr/bin/mporter"
MINTERFACE_MODULE="/usr/bin/minterface"
MDIAG_MODULE="/usr/bin/mdiag"
MSHIELD_MODULE="/usr/bin/mshield"
MSTATS_MODULE="/usr/bin/mstats"
MHEALER_MODULE="/usr/bin/mhealer"
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main"

if [[ ! -x "$MTUNNEL_PATH" ]]; then
    cp "$0" "$MTUNNEL_PATH" 2>/dev/null && chmod +x "$MTUNNEL_PATH" 2>/dev/null
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_main_header() {
    local s_ip=$(get_local_ip)
    
    local st_tuns="○"; local c_tuns="${DIM}"
    if [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] || [ -f "/etc/default/vxlan_meta" ] || [ -d "/etc/wireguard" ]; then st_tuns="●"; c_tuns="${G}"; fi

    local st_hap="○"; local c_hap="${DIM}"
    if pgrep -x "haproxy" >/dev/null 2>&1; then st_hap="●"; c_hap="${G}"; fi

    local st_gost="○"; local c_gost="${DIM}"
    if pgrep -x "gost" >/dev/null 2>&1; then st_gost="●"; c_gost="${G}"; fi

    local st_shld="○"; local c_shld="${DIM}"
    if iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then st_shld="●"; c_shld="${G}"; fi

    clear; echo ""
    local title=" MDesign Master Core v2.2.0 "
    local ip_str=" IP: $s_ip "
    local pad1=$(( 94 - ${#title} - 1 - ${#ip_str} ))
    [ "$pad1" -lt 0 ] && pad1=0
    local spc1=$(printf '%*s' "$pad1" "")

    local srv_str=" NetworkHub: ●   HAProxy: ●   Gost: ●   Shield: ● "
    local pad2=$(( 94 - ${#srv_str} ))
    [ "$pad2" -lt 0 ] && pad2=0
    local spc2=$(printf '%*s' "$pad2" "")

    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM}${ip_str}${NC}${spc1}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} NetworkHub: ${NC}${c_tuns}${st_tuns}${NC}${DIM}   HAProxy: ${NC}${c_hap}${st_hap}${NC}${DIM}   Gost: ${NC}${c_gost}${st_gost}${NC}${DIM}   Shield: ${NC}${c_shld}${st_shld}${NC}${spc2}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ TUNNEL INFRASTRUCTURE HUB ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}      ${DIM}[Layer 3 Routing]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}    ${DIM}[Layer 2 Bridge Over UDP]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}WireGuard Crypto Secure Matrix (Mwire)${NC} ${DIM}[High-Speed Encrypted]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) [ -f "$MGRE_MODULE" ] && bash "$MGRE_MODULE" || (echo -e "\n  ${R}● Module missing!${NC}"; sleep 1.5) ;;
            2) [ -f "$MXLAN_MODULE" ] && bash "$MXLAN_MODULE" || (echo -e "\n  ${R}● Module missing!${NC}"; sleep 1.5) ;;
            3) [ -f "$MWIRE_MODULE" ] && bash "$MWIRE_MODULE" || (echo -e "\n  ${R}● Module missing!${NC}"; sleep 1.5) ;;
            0) break ;;
        esac
    done
}

while true; do
    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ MAIN DASHBOARD ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub (Mgre / Mxlan / Mwire)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover Module (Mporter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix (Minterface)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${W}Network Health & Diagnostics (Mdiag)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing Shield (Mshield)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Traffic Stats (Mstats)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer (Mhealer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${DIM}Update Master Core & All Sub-Modules${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Delete ALL Tunnels & Traces)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}"
    echo ""
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt
    case $opt in
        1) show_tunnel_hub ;;
        2) [ -f "$MPORTER_MODULE" ] && bash "$MPORTER_MODULE" || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        3) [ -f "$MINTERFACE_MODULE" ] && bash "$MINTERFACE_MODULE" || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        4) [ -f "$MDIAG_MODULE" ] && bash "$MDIAG_MODULE" || (echo -e "\n  ${R}● Module missing! Run Update.${NC brush}") ;;
        5) [ -f "$MSHIELD_MODULE" ] && bash "$MSHIELD_MODULE" || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        6) [ -f "$MSTATS_MODULE" ] && bash "$MSTATS_MODULE" || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        7) [ -f "$MHEALER_MODULE" ] && bash "$MHEALER_MODULE" || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        8) 
           echo -e "\n  ${Y}● Syncing components from GitHub Repository...${NC}"
           CACHE_BUST=$(date +%s)
           sh_files="main.sh mgre.sh mporter.sh mdiag.sh minterface.sh mshield.sh mstats.sh mhealer.sh mxlan.sh mwire.sh"
           download_success=true
           for file in $sh_files; do
               wget --timeout=10 --tries=2 -qO "/tmp/${file}_new" "$REPO_BASE/${file}?v=$CACHE_BUST"
               if [ ! -s "/tmp/${file}_new" ]; then download_success=false; break; fi
           done
           if [ "$download_success" = true ]; then
               for file in $sh_files; do
                   if [[ "$file" == "main.sh" ]]; then
                       cat "/tmp/main.sh_new" > "$MTUNNEL_PATH" 2>/dev/null; chmod +x "$MTUNNEL_PATH" 2>/dev/null
                       cat "/tmp/main.sh_new" > "$0"
                   elif [[ "$file" == "mgre.sh" ]]; then cat "/tmp/mgre.sh_new" > "$MGRE_MODULE" 2>/dev/null; chmod +x "$MGRE_MODULE" 2>/dev/null
                   elif [[ "$file" == "mxlan.sh" ]]; then cat "/tmp/mxlan.sh_new" > "$MXLAN_MODULE" 2>/dev/null; chmod +x "$MXLAN_MODULE" 2>/dev/null
                   elif [[ "$file" == "mwire.sh" ]]; then cat "/tmp/mwire.sh_new" > "$MWIRE_MODULE" 2>/dev/null; chmod +x "$MWIRE_MODULE" 2>/dev/null
                   elif [[ "$file" == "mporter.sh" ]]; then cat "/tmp/mporter.sh_new" > "$MPORTER_MODULE" 2>/dev/null; chmod +x "$MPORTER_MODULE" 2>/dev/null
                   elif [[ "$file" == "minterface.sh" ]]; then cat "/tmp/minterface.sh_new" > "$MINTERFACE_MODULE" 2>/dev/null; chmod +x "$MINTERFACE_MODULE" 2>/dev/null
                   elif [[ "$file" == "mdiag.sh" ]]; then cat "/tmp/mdiag.sh_new" > "$MDIAG_MODULE" 2>/dev/null; chmod +x "$MDIAG_MODULE" 2>/dev/null
                   elif [[ "$file" == "mshield.sh" ]]; then cat "/tmp/mshield.sh_new" > "$MSHIELD_MODULE" 2>/dev/null; chmod +x "$MSHIELD_MODULE" 2>/dev/null
                   elif [[ "$file" == "mstats.sh" ]]; then cat "/tmp/mstats.sh_new" > "$MSTATS_MODULE" 2>/dev/null; chmod +x "$MSTATS_MODULE" 2>/dev/null
                   elif [[ "$file" == "mhealer.sh" ]]; then cat "/tmp/mhealer.sh_new" > "$MHEALER_MODULE" 2>/dev/null; chmod +x "$MHEALER_MODULE" 2>/dev/null
                   fi
                   rm -f "/tmp/${file}_new"
               done
               echo -e "  ${G}● Core ecosystem upgraded successfully!${NC}"; sleep 1.5; exec "$0"
           else
               echo -e "  ${R}● Update aborted due to network/CDN errors.${NC}"; rm -f /tmp/*_new; sleep 2
           fi ;;
        9)
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL infrastructure traces? (y/n): ${NC}"; read del_confirm
           if [[ "$del_confirm" == "y" ]]; then
               systemctl stop mgre.service mporter.service haproxy gost 2>/dev/null
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /etc/gost /usr/bin/m*
               echo -e "  ${G}● Purge complete. System is vanilla.${NC}\n"; exit 0
           fi ;;
        0) clear; exit 0 ;;
    esac
done
