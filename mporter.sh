#!/bin/bash
# --- MPorter Modular Core (mporter.sh) | MHDesign 0.1 (HAProxy Core v1.0.2) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

INSTALL_PATH="/usr/bin/mporter"
H_CONF="/etc/haproxy/haproxy.cfg"

if [[ "$1" != "--apply" ]]; then
    if [[ ! -x "$INSTALL_PATH" ]]; then cp "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null; fi
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

create_base_conf() {
    mkdir -p /etc/haproxy
    echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
    echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
}

fix_and_install() {
    echo -e "\n  ${Y}● Optimizing System & Installing HAProxy Core...${NC}"
    sysctl -w fs.file-max=2000000 >/dev/null
    rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock*
    dpkg --configure -a >/dev/null 2>&1
    apt-get update -y >/dev/null 2>&1
    apt-get install -y haproxy socat >/dev/null 2>&1
    
    if systemctl list-unit-files | grep -q haproxy; then
        create_base_conf
        systemctl enable haproxy >/dev/null 2>&1
        systemctl restart haproxy
        echo -e "  ${G}● HAProxy Engine Active!${NC}"
    else echo -e "  ${R}● Installation Failed! Check mirror/APT sources.${NC}"; fi
    sleep 2
}

draw_mporter_header() {
    local s_ip=$(get_local_ip); local core_status="${DIM}○ Offline${NC}"; local raw_status="Offline"; local total_ports=0
    if systemctl is-active --quiet haproxy; then 
        core_status="${G}● Active${NC}"; raw_status="Active"
        total_ports=$(grep -c "frontend ft_[0-9]" "$H_CONF" 2>/dev/null)
    fi
    clear; echo ""
    local str1=" MPorter Core 1.0 "
    local str2=" IP: $s_ip "
    local str3=" ENGINE: $raw_status "
    local str4=" ACTIVE PORTS: $total_ports "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} + 1 + ${#str4} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ENGINE:${NC} ${core_status} ${B}│${NC}${DIM} ACTIVE PORTS:${NC}${Y} ${total_ports} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

show_mappings() {
    echo -e "\n  ${C}Live Port Mappings${NC}"
    if [ ! -f "$H_CONF" ]; then
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} ${DIM}%-90s${NC} ${B}│${NC}\n" " HAProxy engine is not installed or configured."
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
        return
    fi
    local mappings=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | sed 's/:.*//' | sort -n -k1)
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} %b▼ HAProxy Forwarding Rules%b %-61s ${B}│${NC}\n" "${M}" "${NC}" ""
    echo -e "  ${B}├────────────────────────┬───────────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${DIM}%-22s${NC} ${B}│${NC} ${DIM}%-65s${NC} ${B}│${NC}\n" "LOCAL PORT" "TARGET VIRTUAL IP (DESTINATION)"
    echo -e "  ${B}├────────────────────────┼───────────────────────────────────────────────────────────────────┤${NC}"
    if [ -z "$mappings" ]; then printf "  ${B}│${NC} ${DIM}%-89s${NC} ${B}│${NC}\n" "  No active port mappings found."; else
        local total_lines=$(echo "$mappings" | wc -l); local current_line=0
        while read -r line; do
            ((current_line++)); p_num=$(echo $line | awk '{print $1}'); d_ip=$(echo $line | awk '{print $2}')
            local v_icon="├─"; if [ $current_line -eq $total_lines ]; then v_icon="└─"; fi
            printf "  ${B}│${NC} %s Port: %-11s ${B}│${NC} %-65s ${B}│${NC}\n" "${v_icon}" "$p_num" "Forwarding to ❯ $d_ip"
        done <<< "$mappings"
    fi
    echo -e "  ${B}╰────────────────────────┴───────────────────────────────────────────────────────────────────╯${NC}"
}

while true; do
    draw_mporter_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${M}Install & Optimize HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Add Port Mapping (Smart Forwarding)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}View Active Mappings List${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${R}Wipe All Mappings (Reset to Base)${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 60 opt
    case $opt in
        1) fix_and_install ;;
        2) 
           if [ ! -f "$H_CONF" ]; then echo -e "\n  ${R}● Error: HAProxy is not installed!${NC}"; sleep 1.5; continue; fi
           echo -ne "\n  ${C}●${NC} ${W}Enter Target Virtual IP: ${NC}"; read -t 30 target_ip
           target_ip=$(echo "$target_ip" | tr -d '[:space:]')
           echo -ne "  ${C}●${NC} ${W}Enter Local Ports (e.g. 80,443): ${NC}"; read -t 45 raw_ports
           clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
           
           echo -e "\n  ${DIM}┌─[ APPLYING RULES ]${NC}"
           for p in $clean_ports; do
               if grep -q "ft_$p" "$H_CONF" 2>/dev/null; then echo -e "  ${DIM}│${NC} ${R}Port $p mapped! Skipping.${NC}"; continue; fi
               echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
               echo -e "  ${DIM}│${NC} ${G}Port $p ❯❯ Mapped to $target_ip${NC}"
           done
           echo -e "  ${DIM}└───────────────────────────────────────────────────────${NC}"
           systemctl restart haproxy 2>/dev/null; sleep 2 ;;
        3) draw_mporter_header; show_mappings; echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read ;;
        4) 
           echo -ne "\n  ${R}● Wipe all port mappings? (y/n): ${NC}"; read -t 15 confirm
           if [[ "$confirm" == "y" ]]; then create_base_conf; systemctl restart haproxy 2>/dev/null; echo -e "  ${G}● Wiped.${NC}"; sleep 1.5; fi ;;
        0) break ;;
    esac
done
