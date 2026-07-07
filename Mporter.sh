#!/bin/bash
# --- MPorter v1.1 | MDesign Professional Interface (Modern Rounded Edition) ---
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; NC='\033[0m'
H_CONF="/etc/haproxy/haproxy.cfg"

# --- System Functions ---
fix_and_install() {
    echo -e "\n${Y} ❯ Optimizing & Installing Core Components...${NC}"
    sysctl -w fs.file-max=2000000 >/dev/null
    rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock*
    dpkg --configure -a && apt-get install -f -y >/dev/null 2>&1
    apt-get update >/dev/null 2>&1 && apt-get install -y haproxy socat >/dev/null 2>&1
    if [ $? -eq 0 ]; then 
        create_base_conf
        systemctl enable haproxy >/dev/null 2>&1
        systemctl restart haproxy
        echo -e "${G} ❯ Core Ready.${NC}\n"
    fi
    sleep 2
}

create_base_conf() {
    mkdir -p /etc/haproxy
    echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
    echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
}

# --- Smart Interface Detector ---
get_iface_for_ip() {
    local target_ip=$1
    local subnet=$(echo "$target_ip" | cut -d'.' -f1-3)
    local iface=$(ip -o -4 addr show 2>/dev/null | grep "$subnet" | awk '{print $2}' | head -n 1)
    if [ -z "$iface" ]; then echo "Unknown"; else echo "$iface"; fi
}

get_stats() {
    if systemctl is-active --quiet haproxy; then 
        core_status="${G}RUNNING${NC}"; raw_core="RUNNING"
    else 
        core_status="${R}STOPPED${NC}"; raw_core="STOPPED"
    fi
    
    total_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null)
    ((total_ports--))
    [ "$total_ports" -lt 0 ] && total_ports=0

    active_gre_count=$(ls /sys/class/net 2>/dev/null | grep -c '^gre')
    if [ "$active_gre_count" -gt 0 ]; then 
        if_status="${G}${active_gre_count} ACTIVE${NC}"; raw_if="${active_gre_count} ACTIVE"
    else 
        if_status="${R}OFF${NC}"; raw_if="OFF"
    fi
    
    ip_port_counts=$(grep "server srv_" "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d':' -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
}

draw_header() {
    get_stats
    clear
    
    # MDesign Padding Engine (Calculates exactly 95 chars width)
    raw_text=" PROJECT: MPorter v1.1 | CORE: $raw_core | TUNNELS: $raw_if | PORTS: $total_ports "
    pad_len=$(( 93 - ${#raw_text} ))
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "${B}╭─────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${B}│${NC} ${W}PROJECT:${NC} ${Y}MPorter v1.1${NC} | ${W}CORE:${NC} ${core_status} | ${W}TUNNELS:${NC} ${if_status} | ${W}PORTS:${NC} ${G}${total_ports}${NC}${padding} ${B}│${NC}"
    echo -e "${B}├
