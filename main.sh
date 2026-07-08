#!/bin/bash
# --- MHDesign Master Core | Central Dashboard v1.1 ---

# Colors
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

# Paths
MGRE_MODULE="/usr/bin/mgre"
MPORTER_MODULE="/usr/bin/mporter"
MASTER_REPO_URL="https://raw.githubusercontent.com/htzserv/MTunnel/main/main.sh"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_main_header() {
    local s_ip=$(get_local_ip)
    clear
    echo ""
    
    local str1=" MHDesign Master Core "
    local str2=" IP: $s_ip "
    local str3=" STATUS: Active "
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} STATUS:${NC}${G} ${str3}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_main_header
    echo ""
    echo -e "  ${DIM}┌─[ MAIN DASHBOARD ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Manager${NC} ${DIM}(mgre.sh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding Module${NC} ${DIM}(mporter.sh)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Update Master Core & Modules${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Delete ALL Tunnels & MPorter)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}"
    echo ""
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read opt
    
    case $opt in
        1) 
           if [ -f "$MGRE_MODULE" ] && [ -x "$MGRE_MODULE" ]; then
               $MGRE_MODULE
           elif [ -f "./mgre.sh" ]; then
               bash ./mgre.sh
           else
               echo -e "\n  ${R}● Error: mgre.sh module not found! Please run the installer first.${NC}"
               sleep 2
           fi
           ;;
           
        2) 
           if [ -f "$MPORTER_MODULE" ] && [ -x "$MPORTER_MODULE" ]; then
               $MPORTER_MODULE
           elif [ -f "./mporter.sh" ]; then
               bash ./mporter.sh
           else
               echo -e "\n  ${R}● Error: mporter.sh module not found! Please run the installer first.${NC}"
               sleep 2
           fi
           ;;
           
        3) 
           echo -e "\n  ${Y}● Fetching latest Master Core from repository...${NC}"
           wget -qO /tmp/main_new "$MASTER_REPO_URL"
           if [ $? -eq 0 ]; then
               mv /tmp/main_new "$0"
               chmod +x "$0"
               echo -e "  ${G}● Update successful! Reloading Dashboard...${NC}"
               sleep 1.5
               exec "$0"
           else
               echo -e "  ${R}● Update failed. Check URL or internet connection.${NC}"
               sleep 2
           fi
           ;;
           
        4) 
           echo -ne "\n  ${R}● DANGER: Are you sure you want to completely WIPE all Tunnels and MPorter? (y/n): ${NC}"; read confirm
           if [[ "$confirm" == "y" ]]; then
               echo -e "\n  ${DIM}├─ Stopping core services...${NC}"
               systemctl stop mgre.service mporter.service haproxy 2>/dev/null
               systemctl disable mgre.service mporter.service haproxy 2>/dev/null
               
               echo -e "  ${DIM}├─ Destroying all active GRE & IPv6 tunnels...${NC}"
               for conf in /etc/mgre/tunnels/*.conf; do
                   if [ -f "$conf" ]; then
                       source "$conf"
                       iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 >/dev/null 2>&1
                       iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1436 >/dev/null 2>&1
                       ip tunnel del "$T_NAME" >/dev/null 2>&1
                       ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
                   fi
               done
               
               echo -e "  ${DIM}├─ Erasing configurations and binaries...${NC}"
               rm -rf /etc/mgre /etc/mporter /var/lib/haproxy
               rm -f /usr/bin/mgre /usr/bin/mporter
               rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mporter.service
               
               systemctl daemon-reload
               echo -e "  ${G}● System completely purged and reset. Returning to OS...${NC}"
               exit 0
           else
               echo -e "  ${DIM}● Aborted.${NC}"; sleep 1
           fi
           ;;
           
        0) clear; exit 0 ;;
    esac
done
