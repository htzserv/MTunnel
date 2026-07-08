#!/bin/bash
# --- MDesign Master Core | Central Dashboard v1.5 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

# مسیرهای نصب سیستم در خط فرمان
MTUNNEL_PATH="/usr/bin/mtunnel"
MGRE_MODULE="/usr/bin/mgre"
MPORTER_MODULE="/usr/bin/mporter"
REPO_BASE="https://raw.githubusercontent.com/htzserv/MTunnel/main"

# تبدیل خودکار اسکریپت به دستور سراسری سیستم
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
    clear
    echo ""
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
    draw_main_header
    echo ""
    echo -e "  ${DIM}┌─[ MAIN DASHBOARD ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Tunnel Infrastructure Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Port Forwarding Module${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Update Master Core & Modules${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${R}Nuclear Wipe (Delete ALL Tunnels, Scripts & Core Traces)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Terminal${NC}"
    echo ""
    echo -ne "  ${C}CORE ❯❯ ${NC}"; read -t 60 opt
    
    case $opt in
        1) 
           if [ -f "$MGRE_MODULE" ] && [ -x "$MGRE_MODULE" ]; then $MGRE_MODULE;
           elif [ -f "./mgre.sh" ]; then bash ./mgre.sh;
           else echo -e "\n  ${R}● Error: Tunnel module not found!${NC}"; sleep 2; fi ;;
           
        2) 
           if [ -f "$MPORTER_MODULE" ] && [ -x "$MPORTER_MODULE" ]; then $MPORTER_MODULE;
           elif [ -f "./mporter.sh" ]; then bash ./mporter.sh;
           else echo -e "\n  ${R}● Error: Port Forwarding module not found!${NC}"; sleep 2; fi ;;
           
        3) 
           echo -e "\n  ${Y}● Fetching latest Core Modules from Repository...${NC}"
           
           wget --timeout=10 --tries=2 -qO /tmp/main_new "$REPO_BASE/main.sh"
           wget --timeout=10 --tries=2 -qO /tmp/mgre_new "$REPO_BASE/mgre.sh"
           wget --timeout=10 --tries=2 -qO /tmp/mporter_new "$REPO_BASE/mporter.sh"
           
           if [ $? -eq 0 ] && [ -s /tmp/main_new ] && [ -s /tmp/mgre_new ] && [ -s /tmp/mporter_new ]; then
               echo -e "  ${DIM}├─ Purging old workspace files...${NC}"
               rm -f ./mgre.sh ./mporter.sh
               
               echo -e "  ${DIM}├─ Deploying fresh modules...${NC}"
               mv /tmp/main_new "$0"
               mv /tmp/mgre_new "./mgre.sh"
               mv /tmp/mporter_new "./mporter.sh"
               chmod +x "$0" ./mgre.sh ./mporter.sh
               
               if [ -f "$MGRE_MODULE" ]; then cp ./mgre.sh "$MGRE_MODULE" && chmod +x "$MGRE_MODULE"; fi
               if [ -f "$MPORTER_MODULE" ]; then cp ./mporter.sh "$MPORTER_MODULE" && chmod +x "$MPORTER_MODULE"; fi
               
               # آپدیت کردن دستور گلوبال mtunnel در سیستم
               cp "$0" "$MTUNNEL_PATH" 2>/dev/null && chmod +x "$MTUNNEL_PATH" 2>/dev/null
               
               echo -e "  ${G}● All modules updated successfully! Reloading Dashboard...${NC}"
               sleep 1.5
               exec "$0"
           else 
               echo -e "  ${R}● Update failed! Check network connection or repository files.${NC}"
               rm -f /tmp/main_new /tmp/mgre_new /tmp/mporter_new
               sleep 2
           fi ;;
           
        4) 
           echo -ne "\n  ${R}● DANGER: Completely wipe ALL tunnels, configurations, scripts, and traces? (y/n): ${NC}"; read del_confirm
           if [[ "$del_confirm" == "y" ]]; then
               echo -e "\n  ${DIM}├─ Stopping and disabling all system services...${NC}"
               systemctl stop mgre.service mporter.service haproxy 2>/dev/null
               systemctl disable mgre.service mporter.service haproxy 2>/dev/null
               
               echo -e "  ${DIM}├─ Dismantling interfaces and cleansing firewall rules...${NC}"
               if [ -d "/etc/mgre/tunnels" ]; then
                   for conf in /etc/mgre/tunnels/*.conf; do
                       if [ -f "$conf" ]; then
                           source "$conf"
                           iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1396 >/dev/null 2>&1
                           iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss 1436 >/dev/null 2>&1
                           ip tunnel del "$T_NAME" >/dev/null 2>&1
                           ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
                       fi
                   done
               fi
               
               for link in $(ip link show | awk -F': ' '/greir|grekh|sit_gre/ {print $2}' | cut -d'@' -f1); do
                   ip tunnel del "$link" >/dev/null 2>&1
                   ip link del "$link" >/dev/null 2>&1
               done

               echo -e "  ${DIM}├─ Purging all binary executables and core directories...${NC}"
               rm -rf /etc/mgre /etc/mporter /var/lib/haproxy /etc/haproxy
               # پاک کردن دستور mtunnel از سیستم
               rm -f /usr/bin/mgre /usr/bin/mporter /usr/bin/mtunnel
               rm -f /etc/systemd/system/mgre.service /etc/systemd/system/mporter.service
               systemctl daemon-reload
               
               echo -e "  ${DIM}├─ Self-destructing project folder...${NC}"
               current_dir=$(pwd)
               if [[ "$current_dir" == *"/MTunnel"* ]]; then
                   cd .. && rm -rf "$current_dir"
               fi
               
               echo -e "  ${G}● Purge complete. No traces left. System is vanilla.${NC}\n"
               exit 0
           else echo -e "  ${DIM}● Aborted.${NC}"; sleep 1; fi ;;
        0) clear; exit 0 ;;
    esac
done
