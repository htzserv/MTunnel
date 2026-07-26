#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v7.3.0 ---
# [PATCHED: Input validation and basic flocking added]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
H_CONF="/etc/haproxy/haproxy.cfg"

smart_map() {
    echo -ne "  ${C}●${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
    target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
    
    if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return
    fi
    
    echo -ne "\n  ${C}●${NC} ${W}Enter Exact Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports
    if ! [[ "$raw_ports" =~ ^[0-9,]+$ ]]; then
        echo -e "  ${R}● Invalid port format! Use numbers and commas only.${NC}"; sleep 1.5; return
    fi
    
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    for p in $clean_ports; do
        # Using simple subshell and lock for editing config
        (
            flock -x 200
            echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
        ) 200>/var/lock/mporter_haproxy.lock
    done
    systemctl restart haproxy 2>/dev/null
    echo -e "\n  ${G}● Mapped successfully!${NC}"; sleep 1
}

echo "MPorter is running. Validated inputs applied."
