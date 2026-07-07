#!/bin/bash
# --- MapRoxy v6.2 | MDesign Professional Interface (Dynamic Multi-Core) ---
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
    # محاسبه متغیرهای خام برای تنظیم دقیق کادرها
    if systemctl is-active --quiet haproxy; then 
        core_status="${G}RUNNING${NC}"; raw_core="RUNNING"
    else 
        core_status="${R}STOPPED${NC}"; raw_core="STOPPED"
    fi
    
    total_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null)
    ((total_ports--)) # کسر کردن dummy_check
    [ "$total_ports" -lt 0 ] && total_ports=0

    active_gre_count=$(ls /sys/class/net 2>/dev/null | grep -c '^gre')
    if [ "$active_gre_count" -gt 0 ]; then 
        if_status="${G}${active_gre_count} ACTIVE${NC}"; raw_if="${active_gre_count} ACTIVE"
    else 
        if_status="${R}OFF${NC}"; raw_if="OFF"
    fi
    
    # استخراج آی‌پی‌های درگیر و تعداد پورت‌های مپ شده روی هرکدام
    ip_port_counts=$(grep "server srv_" "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d':' -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
}

draw_header() {
    get_stats
    clear
    
    # تنظیم داینامیک طول خط بالای هدر برای جلوگیری از به هم ریختگی کادر
    top_line=" PROJECT: MapRoxy v6.2 | CORE: $raw_core | GRE TUNNELS: $raw_if | TOTAL PORTS: $total_ports "
    pad_len=$(( 86 - ${#top_line} ))
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "${B}┌────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${B}│${NC} ${W}PROJECT:${NC} ${Y}MapRoxy v6.2${NC} | ${W}CORE:${NC} ${core_status} | ${W}GRE TUNNELS:${NC} ${if_status} | ${W}TOTAL PORTS:${NC} ${G}${total_ports}${NC}${padding} ${B}│${NC}"
    echo -e "${B}├──────────────────────────────────[ ACTIVE MAPPINGS ]───────────────────────────────────┤${NC}"
    
    # جدول داینامیک آی‌پی‌ها
    if [ -z "$ip_port_counts" ]; then
        printf "${B}│${NC} ${Y}%-86s${NC} ${B}│${NC}\n" "  No active mapped IPs yet."
    else
        printf "${B}│${NC} ${W}  %-40s${NC} | ${W}%-41s${NC} ${B}│${NC}\n" "Target Network IP" "Active Forwarded Ports"
        echo -e "${B}│${NC} ${B}---------------------------------------------+-------------------------------------------${NC} ${B}│${NC}"
        while IFS='|' read -r ip count; do
            if [ -n "$ip" ]; then
                printf "${B}│${NC} ${G}  %-40s${NC} | ${Y}%-41s${NC} ${B}│${NC}\n" "$ip" "$count Ports Forwarding"
            fi
        done <<< "$ip_port_counts"
    fi
    echo -e "${B}└────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
}

# --- بخش ۲: مپینگ هوشمند با پشتیبانی از بی‌نهایت آی‌پی ---
smart_map() {
    draw_header
    
    local gre_ifs=($(ls /sys/class/net 2>/dev/null | grep '^gre'))
    if [ ${#gre_ifs[@]} -eq 0 ]; then
        echo -e "${R}No GRE interfaces found on this server!${NC}"
        echo -ne "${Y}Enter IP manually: ${NC}"; read manual_ip; selected_ips=("$manual_ip")
    else
        echo -e "${B}┌────────────────── Available GRE Interfaces ──────────────────┐${NC}"
        for i in "${!gre_ifs[@]}"; do 
            printf "${B}│${NC} ${W}[%d]${NC} ${G}%-54s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"
        done
        echo -e "${B}└──────────────────────────────────────────────────────────────┘${NC}"
        echo -ne "${G}Select Interface (0-$(( ${#gre_ifs[@]} - 1 ))): ${NC}"; read if_choice
        
        if [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
        else 
            echo -e "${R}Invalid selection!${NC}"; sleep 1; return
        fi
        
        local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
        if [ ${#map_ips[@]} -eq 0 ]; then
            echo -e "${R}No active IPs found on ${selected_if}!${NC}"
            echo -ne "${Y}Enter IP manually: ${NC}"; read manual_ip; selected_ips=("$manual_ip")
        else
            echo -e "\n${B}┌────────────────── IPs on ${selected_if} ──────────────────┐${NC}"
            for i in "${!map_ips[@]}"; do 
                printf "${B}│${NC} ${W}[%d]${NC} ${G}%-52s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"
            done
            echo -e "${B}└──────────────────────────────────────────────────────────────┘${NC}"
            echo -e "${Y}Tip: Enter 'a' to randomize across all IPs on this interface.${NC}"
            echo -ne "${G}Select Index (0-$(( ${#map_ips[@]} - 1 ))) or 'a': ${NC}"; read ip_choice
            
            if [[ "$ip_choice" == "a" ]]; then 
                selected_ips=("${map_ips[@]}")
            elif [[ -n "${map_ips[$ip_choice]}" ]]; then 
                selected_ips=("${map_ips[$ip_choice]}")
            else 
                echo -e "${R}Invalid selection!${NC}"; sleep 1; return
            fi
        fi
    fi

    echo -ne "\n${G}Enter Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    
    echo -e "\n${Y}Applying Mappings...${NC}"
    echo -e "${B}┌──────────────┬──────────────────────────────────────────────────┐${NC}"
    printf "${B}│${W} %-12s ${B}│${W} %-48s ${B}│${NC}\n" "Local Port" "Assigned Target IP"
    echo -e "${B}├──────────────┼──────────────────────────────────────────────────┤${NC}"
    
    for p in $clean_ports; do
        # بررسی دقیق جلوگیری از تداخل پورت‌ها
        if grep -q -w "frontend ft_$p" "$H_CONF" 2>/dev/null; then 
            printf "${B}│${R} %-12s ${B}│${NC} %-48s ${B}│${NC}\n" "$p" "Error: Port in use! (Skipped)"
            continue 
        fi
        
        target_ip=$(echo ${selected_ips[$((RANDOM % ${#selected_ips[@]}))]} | cut -d'.' -f1-3).2
        [ -n "$manual_ip" ] && target_ip="$manual_ip"
        
        echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
        printf "${B}│${G} %-12s ${B}│${NC} %-48s ${B}│${NC}\n" "$p" "$target_ip"
    done
    
    echo -e "${B}└──────────────┴──────────────────────────────────────────────────┘${NC}"
    systemctl restart haproxy 2>/dev/null
    echo -ne "\n${G}Success! Operations completed. Press Enter...${NC}"; read
}

show_table() {
    draw_header
    echo -e "${Y}Detailed Port -> IP Matrix:${NC}"
    echo -e "${B}┌──────────────┬─────────────────────────────────────────────────────────────────────────┐${NC}"
    printf "${B}│${W} %-12s ${B}│${W} %-71s ${B}│${NC}\n" "Local Port" "Target IP"
    echo -e "${B}├──────────────┼─────────────────────────────────────────────────────────────────────────┤${NC}"
    local mappings=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | sed 's/:.*//' | sort -n -k1)
    if [ -z "$mappings" ]; then 
        printf "${B}│${NC} %-86s ${B}│${NC}\n" "${R}No active mappings.${NC}"
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
    printf "  ${Y}[2]${NC} ${G}%-45s${NC}\n" "Add Port Mappings (Multipoint)"
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
        0) clear; exit 0 ;;
    esac
done
