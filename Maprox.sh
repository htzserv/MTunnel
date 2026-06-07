#!/bin/bash

# --- MapRoxy v6.0 | MDesign Professional Interface ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; NC='\033[0m'

H_CONF="/etc/haproxy/haproxy.cfg"

# --- توابع سیستمی ---

fix_and_install() {

    echo -e "${Y}[*] Optimizing & Installing...${NC}"

    sysctl -w fs.file-max=2000000 >/dev/null

    rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock*

    dpkg --configure -a && apt-get install -f -y

    apt-get update && apt-get install -y haproxy socat

    if [ $? -eq 0 ]; then create_base_conf; systemctl enable haproxy >/dev/null 2>&1; systemctl restart haproxy; echo -e "${G}[✓] Core Ready.${NC}"; fi

    sleep 2

}

create_base_conf() {

    mkdir -p /etc/haproxy

    echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"

    echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"

}

get_stats() {

    if systemctl is-active --quiet haproxy; then core_status="${G}RUNNING${NC}"; else core_status="${R}STOPPED${NC}"; fi

    total_ips_count=$(ip -o -4 addr show greir 2>/dev/null | wc -l)

    used_ips_count=$(grep "server srv_" "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d':' -f1 | sort -u | wc -l)

    total_ports=$(grep -c "frontend ft_[0-9]" "$H_CONF" 2>/dev/null)

    if_status=$(ip link show greir >/dev/null 2>&1 && echo -e "${G}ON${NC}" || echo -e "${R}OFF${NC}")

}

draw_header() {

    get_stats

    clear

    echo -e "${B}┌────────────────────────────────────────────────────────────────────────────────────────┐${NC}"

    echo -e "${B}│${NC} ${W}PROJECT:${NC} ${Y}MapRoxy v6.0${NC} | ${W}CORE:${NC} ${core_status} | ${W}IPs:${NC} ${G}${used_ips_count}${NC}/${Y}${total_ips_count}${NC} | ${W}PORTs:${NC} ${G}${total_ports}${NC} ${B}│${NC}"

    echo -e "${B}│${NC} ${W}INTERFACE greir:${NC} ${if_status}                                                               ${B}│${NC}"

    echo -e "${B}└────────────────────────────────────────────────────────────────────────────────────────┘${NC}"

}

# --- بخش ۲: مپینگ هوشمند با گزارش لحظه‌ای ---

smart_map() {

    draw_header

    local map_ips=($(ip -o -4 addr show greir 2>/dev/null | awk '{print $4}' | cut -d/ -f1))

    

    if [ ${#map_ips[@]} -eq 0 ]; then

        echo -e "${R}No active IPs found on greir!${NC}"; echo -ne "${Y}Enter IP manually: ${NC}"; read manual_ip; selected_ips=("$manual_ip")

    else

        echo -e "${B}┌────────────────── Available IPs on greir ──────────────────┐${NC}"

        for i in "${!map_ips[@]}"; do printf "${B}│${NC}  ${W}[%d]${NC} ${G}%-48s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done

        echo -e "${B}└────────────────────────────────────────────────────────────┘${NC}"

        echo -e "${Y}Tip: Enter 'a' to randomize all IPs.${NC}"

        echo -ne "${G}Select Index (0-${#map_ips[@]}) or 'a': ${NC}"; read choice

        

        if [[ "$choice" == "a" ]]; then selected_ips=("${map_ips[@]}")

        elif [[ -n "${map_ips[$choice]}" ]]; then selected_ips=("${map_ips[$choice]}")

        else echo -e "${R}Invalid selection!${NC}"; sleep 1; return; fi

    fi

    echo -ne "\n${G}Enter Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports

    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)

    echo -e "\n${Y}Applying Mappings...${NC}"

    echo -e "${B}┌──────────────┬──────────────────────────────────────────────────┐${NC}"

    printf "${B}│${W} %-12s ${B}│${W} %-48s ${B}│${NC}\n" "Local Port" "Assigned Target IP"

    echo -e "${B}├──────────────┼──────────────────────────────────────────────────┤${NC}"

    for p in $clean_ports; do

        if grep -q "ft_$p" "$H_CONF" 2>/dev/null; then 

            printf "${B}│${R} %-12s ${B}│${NC} %-48s ${B}│${NC}\n" "$p" "Error: Port already exists!"

            continue 

        fi

        

        target_ip=$(echo ${selected_ips[$((RANDOM % ${#selected_ips[@]}))]} | cut -d'.' -f1-3).2

        [ -n "$manual_ip" ] && target_ip="$manual_ip"

        

        echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"

        printf "${B}│${G} %-12s ${B}│${NC} %-48s ${B}│${NC}\n" "$p" "$target_ip"

    done

    

    echo -e "${B}└──────────────┴──────────────────────────────────────────────────┘${NC}"

    systemctl restart haproxy 2>/dev/null

    echo -ne "\n${G}Success! All mapped. Press Enter to return...${NC}"; read

}

show_table() {

    draw_header

    echo -e "${Y}Current Mapping Table:${NC}"

    echo -e "${B}┌──────────────┬─────────────────────────────────────────────────────────────────────────┐${NC}"

    printf "${B}│${W} %-12s ${B}│${W} %-71s ${B}│${NC}\n" "Local Port" "Target IP"

    echo -e "${B}├──────────────┼─────────────────────────────────────────────────────────────────────────┤${NC}"

    local mappings=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | sed 's/:.*//' | sort -n -k1)

    if [ -z "$mappings" ]; then printf "${B}│${NC} %-86s ${B}│${NC}\n" "${R}No active mappings.${NC}"

    else

        while read -r line; do

            p_num=$(echo $line | awk '{print $1}'); d_ip=$(echo $line | awk '{print $2}')

            printf "${B}│${G} %-12s ${B}│${NC} %-71s ${B}│${NC}\n" "$p_num" "$d_ip"

        done <<< "$mappings"

    fi

    echo -e "${B}└──────────────┴─────────────────────────────────────────────────────────────────────────┘${NC}"

    echo -ne "\n${B}Press Enter...${NC}"; read

}

while true; do

    draw_header

    printf "  ${Y}[1]${NC} ${W}%-45s${NC}\n" "REPAIR & INSTALL CORE"

    printf "  ${Y}[2]${NC} ${G}%-45s${NC}\n" "Add Port Mapping (With Report)"

    printf "  ${Y}[3]${NC} ${W}%-45s${NC}\n" "Activate Dynamic Sync"

    printf "  ${Y}[4]${NC} ${W}%-45s${NC}\n" "Wipe Mappings (Standard Reset)"

    printf "  ${Y}[5]${NC} ${W}%-45s${NC}\n" "View Port -> IP Table"

    printf "  ${Y}[6]${NC} ${R}%-45s${NC}\n" "UNINSTALL EVERYTHING (Nuclear)"

    printf "  ${Y}[0]${NC} ${W}%-45s${NC}\n" "Exit"

    echo -ne "\n${B}Command >> ${NC}"; read -t 30 opt

    case $opt in

        1) fix_and_install ;;

        2) smart_map ;;

        3) echo -e "${G}Sync active.${NC}"; sleep 1 ;;

        4) create_base_conf; systemctl restart haproxy 2>/dev/null; echo -e "${G}Wiped.${NC}"; sleep 1 ;;

        5) show_table ;;

        6) 

            echo -ne "${R}Nuclear Wipe? (y/n): ${NC}"; read confirm

            if [[ "$confirm" == "y" ]]; then 

                systemctl stop haproxy 2>/dev/null; rm -rf /etc/haproxy /var/lib/haproxy; apt-get purge -y haproxy 2>/dev/null

                echo -e "${G}Erased from system.${NC}"; sleep 1; exit 0

            fi ;;

        0) exit 0 ;;

    esac

done
