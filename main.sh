#!/bin/bash
# --- MDesign Master Core | Central Dashboard v1.9.5 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

MTUNNEL_PATH="/usr/bin/mtunnel"
MGRE_MODULE="/usr/bin/mgre"
MPORTER_MODULE="/usr/bin/mporter"
MDIAG_MODULE="/usr/bin/mdiag"
MINTERFACE_MODULE="/usr/bin/minterface"
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
    clear; echo ""
    local str1=" MDesign Master Core "
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
    draw_main_header; echo ""
    echo -e "  ${DIM}┌─[ MAIN DASHBOARD ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding & Failover Module${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Interface Blueprint Matrix${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${W}Network Health & Diagnostics${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Update Master Core & Modules${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Delete ALL Tunnels & Traces)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}"
    echo ""
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read -t 60 opt
    
    case $opt in
        1) [ -x "$MGRE_MODULE" ] && $MGRE_MODULE || (echo -e "\n  ${R}● Module missing!${NC}"; sleep 1.5) ;;
        2) [ -x "$MPORTER_MODULE" ] && $MPORTER_MODULE || (echo -e "\n  ${R}● Module missing!${NC}"; sleep 1.5) ;;
        3) [ -x "$MINTERFACE_MODULE" ] && $MINTERFACE_MODULE || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        4) [ -x "$MDIAG_MODULE" ] && $MDIAG_MODULE || (echo -e "\n  ${R}● Module missing! Run Update.${NC}"; sleep 1.5) ;;
        5) 
           echo -e "\n  ${Y}● Syncing latest components from GitHub...${NC}"
           CACHE_BUST=$(date +%s)
           sh_files="main.sh mgre.sh mporter.sh mdiag.sh minterface.sh"
           download_success=true
           
           for file in $sh_files; do
               echo -e "  ${DIM}├─ Fetching $file...${NC}"
               wget --timeout=10 --tries=2 -qO "/tmp/${file}_new" "$REPO_BASE/${file}?v=$CACHE_BUST"
               if [ ! -s "/tmp/${file}_new" ]; then download_success=false; break; fi
           done
           
           if [ "$download_success" = true ]; then
               for file in $sh_files; do
                   cat "/tmp/${file}_new" > "./$file" 2>/dev/null; chmod +x "./$file" 2>/dev/null
                   if [[ "$file" == "main.sh" ]]; then
                       cat "/tmp/main.sh_new" > "$MTUNNEL_PATH" 2>/dev/null; chmod +x "$MTUNNEL_PATH" 2>/dev/null
                       cat "/tmp/main.sh_new" > "$0"
                   elif [[ "$file" == "mgre.sh" ]]; then cat "/tmp/mgre.sh_new" > "$MGRE_MODULE" 2>/dev/null
                   elif [[ "$file" == "mporter.sh" ]]; then cat "/tmp/mporter.sh_new" > "$MPORTER_MODULE" 2>/dev/null
                   elif [[ "$file" == "mdiag.sh" ]]; then cat "/tmp/mdiag.sh_new" > "$MDIAG_MODULE" 2>/dev/null
                   elif [[ "$file" == "minterface.sh" ]]; then cat "/tmp/minterface.sh_new" > "$MINTERFACE_MODULE" 2>/dev/null; chmod +x "$MINTERFACE_MODULE" 2>/dev/null
                   fi
                   rm -f "/tmp/${file}_new"
               done
               echo -e "  ${G}● All modules updated successfully! Reloading...${NC}"; sleep 1.5; exec "$0"
           else
               echo -e "  ${R}● Update aborted due to network/CDN errors.${NC}"
               rm -f /tmp/*_new; sleep 2
           fi ;;
        6) 
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL tunnels and scripts? (y/n): ${NC}"; read del_confirm
           if [[ "$del_confirm" == "y" ]]; then
               systemctl stop mgre.service mporter.service haproxy gost 2>/dev/null
               systemctl disable mgre.service mporter.service haproxy gost 2>/dev/null
               if [ -d "/etc/mgre/tunnels" ]; then
                   for conf in /etc/mgre/tunnels/*.conf; do
                       if [ -f "$conf" ]; then
                           source "$conf"; ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
                       fi
                   done
               fi
               rm -rf /etc/mgre /etc/mporter /etc/haproxy /var/lib/haproxy /etc/gost /usr/bin/mgre /usr/bin/mporter /usr/bin/mdiag /usr/bin/minterface /usr/bin/mtunnel
               systemctl daemon-reload; echo -e "  ${G}● Purge complete. System is vanilla.${NC}\n"; exit 0
           else echo -e "  ${DIM}● Aborted.${NC}"; sleep 1; fi ;;
        0) clear; exit 0 ;;
    esac
done
