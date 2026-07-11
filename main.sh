#!/bin/bash
# --- MDesign Master Core | Central Dashboard v3.0.0 (Modern UI) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

MTUNNEL_PATH="/usr/bin/mtunnel"
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main"

# اطمینان از اینکه فایل اجرایی وجود داره
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
    
    local st_gre="○"; local c_gre="${DIM}"; [ -n "$(ls -A /etc/mgre/tunnels/*.conf 2>/dev/null)" ] && { st_gre="●"; c_gre="${G}"; }
    local st_vx="○"; local c_vx="${DIM}"; [ -n "$(ls -A /etc/mgre/vxlan/*.conf 2>/dev/null)" ] && { st_vx="●"; c_vx="${G}"; }
    local st_wg="○"; local c_wg="${DIM}"; ([ -f "/etc/wireguard/wg0.conf" ] || ip link show wg0 >/dev/null 2>&1) && { st_wg="●"; c_wg="${G}"; }
    local st_hap="○"; local c_hap="${DIM}"; pgrep -x "haproxy" >/dev/null 2>&1 && { st_hap="●"; c_hap="${G}"; }
    local st_gost="○"; local c_gost="${DIM}"; pgrep -x "gost" >/dev/null 2>&1 && { st_gost="●"; c_gost="${G}"; }
    local st_shld="○"; local c_shld="${DIM}"; iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null && { st_shld="●"; c_shld="${G}"; }

    clear; echo ""
    local title=" MDesign Master Core v3.0 "
    local ip_str=" IP: $s_ip "
    local pad1=$(( 94 - ${#title} - 1 - ${#ip_str} ))
    [ "$pad1" -lt 0 ] && pad1=0
    local spc1=$(printf '%*s' "$pad1" "")
    local pad2=$(( 94 - 81 ))
    [ "$pad2" -lt 0 ] && pad2=0
    local spc2=$(printf '%*s' "$pad2" "")

    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${title}${NC}${B}│${NC}${DIM}${ip_str}${NC}${spc1}${B}│${NC}"
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}${DIM} Hub:  GRE: ${NC}${c_gre}${st_gre}${NC}${DIM}    VXLAN: ${NC}${c_vx}${st_vx}${NC}${DIM}    WireGuard: ${NC}${c_wg}${st_wg}${NC}${DIM}  │  HAProxy: ${NC}${c_hap}${st_hap}${NC}${DIM}    Gost: ${NC}${c_gost}${st_gost}${NC}${DIM}    Shield: ${NC}${c_shld}${st_shld}${NC}${spc2}${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_tunnel_hub() {
    while true; do
        draw_main_header; echo ""
        echo -e "  ${DIM}┌─[ TUNNEL INFRASTRUCTURE HUB ]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Modular GRE/IP6GRE Core (Mgre)${NC}      ${DIM}[Layer 3 Routing]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}VXLAN Virtual Mesh Fabric (Mxlan)${NC}    ${DIM}[Layer 2 Bridge]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}WireGuard Crypto Matrix (Mwire)${NC}      ${DIM}[High-Speed VPN]${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core Dashboard${NC}\n"
        echo -ne "  ${C}TUNNEL ❯❯ ${NC}"; read t_opt
        case $t_opt in
            1) [ -f "/usr/bin/mgre" ] && mgre || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
            2) [ -f "/usr/bin/mxlan" ] && mxlan || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
            3) [ -f "/usr/bin/mwire" ] && mwire || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
            0) break ;;
        esac
    done
}

while true; do
    draw_main_header; echo ""
    
    # Modern Block Layout
    echo -e "  ${DIM}┌─[ CORE NETWORK & ROUTING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Hub${NC} ${DIM}(GRE / VXLAN / WireGuard)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover${NC} ${DIM}(Mporter)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC} ${DIM}(Minterface)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SECURITY & ANALYTICS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Stealth Anti-Probing Shield${NC} ${DIM}(Mshield)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${B}Bandwidth Radar & Web UI${NC} ${DIM}(Mstats & Mweb)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Autonomous Tunnel Healer${NC} ${DIM}(Mhealer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Network Diagnostics Tools${NC} ${DIM}(Mdiag)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Update Master Core & Modules${NC} ${DIM}(Sync with GitHub)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${R}Nuclear Wipe${NC} ${DIM}(Delete ALL Tunnels & Traces)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}"
    echo ""
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt

    case $opt in
        1) show_tunnel_hub ;;
        2) [ -f "/usr/bin/mporter" ] && mporter || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        3) [ -f "/usr/bin/minterface" ] && minterface || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        4) [ -f "/usr/bin/mshield" ] && mshield || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        5) [ -f "/usr/bin/mstats" ] && mstats || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        6) [ -f "/usr/bin/mhealer" ] && mhealer || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        7) [ -f "/usr/bin/mdiag" ] && mdiag || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        8) 
           echo -e "\n  ${Y}● Syncing components from GitHub Repository...${NC}"
           CACHE_BUST=$(date +%s)
           # Dynamic Module Array Array (Same as Installer)
           MODULES=("main.sh" "mgre.sh" "mxlan.sh" "mwire.sh" "mporter.sh" "minterface.sh" "mdiag.sh" "mshield.sh" "mstats.sh" "mhealer.sh" "mweb.sh")
           download_success=true
           
           for file in "${MODULES[@]}"; do
               echo -e "  ${DIM}├─ Fetching $file...${NC}"
               wget --timeout=10 --tries=2 -qO "/tmp/${file}_new" "$REPO_BASE/${file}?v=$CACHE_BUST"
               if [ ! -s "/tmp/${file}_new" ]; then download_success=false; break; fi
           done
           
           if [ "$download_success" = true ]; then
               for file in "${MODULES[@]}"; do
                   mod_name="${file%.sh}"
                   if [ "$mod_name" == "main" ]; then mod_name="mtunnel"; fi
                   cat "/tmp/${file}_new" > "/usr/bin/$mod_name" 2>/dev/null
                   chmod +x "/usr/bin/$mod_name" 2>/dev/null
                   rm -f "/tmp/${file}_new"
               done
               echo -e "\n  ${G}● Core ecosystem upgraded successfully!${NC}"; sleep 1.5; exec "$0"
           else
               echo -e "\n  ${R}● Update aborted due to network/CDN errors.${NC}"; rm -f /tmp/*_new; sleep 2
           fi ;;
        9)
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL infrastructure traces? (y/n): ${NC}"; read del_confirm
           if [[ "$del_confirm" == "y" ]]; then
               systemctl stop mgre.service mporter.service haproxy gost wg-quick@wg0 mxlan.service mweb.service mstats-web.service 2>/dev/null
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /etc/gost /etc/wireguard /etc/mweb /usr/bin/m*
               echo -e "  ${G}● Purge complete. System is vanilla.${NC}\n"; exit 0
           fi ;;
        0) clear; exit 0 ;;
    esac
done
