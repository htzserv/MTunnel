#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v7.7.0 ---
# [PATCHED: Enhanced Progress Bar, Cleaned Extra Engines, HAProxy 1-to-1 Multiplexing]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mporter"
H_CONF="/etc/haproxy/haproxy.cfg"
LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

mkdir -p "$LOCAL_DIR/packages" /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/sbin /usr/local/bin 2>/dev/null
if [ -f "$0" ] && [ "$0" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

get_pkg_dir() {
    if [ -d "$LOCAL_DIR/packages" ] && [ "$(ls -A "$LOCAL_DIR/packages" 2>/dev/null)" ]; then echo "$LOCAL_DIR/packages"
    elif [ -d "$SCRIPT_DIR/packages" ] && [ "$(ls -A "$SCRIPT_DIR/packages" 2>/dev/null)" ]; then echo "$SCRIPT_DIR/packages"
    elif [ -d "./packages" ] && [ "$(ls -A "./packages" 2>/dev/null)" ]; then echo "./packages"
    else echo "$LOCAL_DIR/packages"; fi
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=28; local progress=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++)); [ "$progress" -gt 95 ] && progress=95
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  ${C}⟳${NC} ${W}%-24s${NC} ${B}[${G}%s${DIM}%s${B}]${NC} ${C}%3d%%${NC}" "$text" "$bar" "$empty_bar" "$progress"
        sleep 0.12
    done
    local bar=$(printf "%${width}s" "" | tr ' ' '#')
    printf "\r  ${G}✔${NC} ${W}%-24s${NC} ${B}[${G}%s${B}]${NC} ${G}100%%${NC}\n" "$text" "$bar"
    tput cnorm 2>/dev/null || true
}

purge_ip_core() {
    local target_ip="$1"
    local t_ports=""
    
    [ -f "$H_CONF" ] && t_ports+=$(grep "$target_ip:" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
    t_ports=$(echo "$t_ports" | tr ' ' '\n' | grep -v '^$' | sort -un | xargs)
    
    for p in $t_ports; do
        sed -i "/frontend ft_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/bind \*:$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/default_backend bk_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/backend bk_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/server srv_$p /d" "$H_CONF" 2>/dev/null
        sed -i "/server srv_${p}_[0-9]\+ /d" "$H_CONF" 2>/dev/null
    done
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
    echo "$(date) | Deep Purged Target IP: $target_ip and its associated ports." >> /var/log/mporter-watchdog.log
}

# --- 🌟 BACKEND APIs 🌟 ---
if [[ "$1" == "--purge-ip" && -n "$2" ]]; then
    purge_ip_core "$2"
    systemctl restart haproxy 2>/dev/null
    exit 0
fi

if [[ "$1" == "--cleanup-orphans" ]]; then
    h_ips=$(grep -oP 'server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null | sort -u)
    all_ips=$(echo -e "$h_ips" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | sort -u)
    
    for ip in $all_ips; do
        subnet=$(echo "$ip" | cut -d'.' -f1-3)
        found=false
        grep -qR "CORE_SUBNET=$subnet" /etc/mgre/ 2>/dev/null && found=true
        
        if [ "$found" = false ]; then
            purge_ip_core "$ip"
        fi
    done
    systemctl restart haproxy 2>/dev/null
    exit 0
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

install_haproxy_core() {
    (
        local P_DIR=$(get_pkg_dir)
        mkdir -p /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/sbin 2>/dev/null
        touch /var/lib/haproxy/stats 2>/dev/null

        if ls "$P_DIR"/haproxy*.deb >/dev/null 2>&1; then
            dpkg -i "$P_DIR"/haproxy*.deb >/dev/null 2>&1 || true
            apt-get --fix-broken install -y >/dev/null 2>&1 || true
        elif [ -s "$P_DIR/haproxy" ]; then
            cp -f "$P_DIR/haproxy" /usr/sbin/haproxy 2>/dev/null
            chmod +x /usr/sbin/haproxy 2>/dev/null
        else
            DEBIAN_FRONTEND=noninteractive apt-get update -y -q >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends liblua5.4-0 haproxy >/dev/null 2>&1 || true
        fi

        if [ ! -s "$H_CONF" ]; then
            cat <<'EOF_HAP' > "$H_CONF"
global
    maxconn 500000
    daemon
defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend dummy_check
    bind 127.0.0.1:9999
    default_backend dummy_back
backend dummy_back
    server local 127.0.0.1:9999
EOF_HAP
        fi

        local HAP_BIN="/usr/sbin/haproxy"
        [ ! -f "$HAP_BIN" ] && [ -f "/usr/local/sbin/haproxy" ] && HAP_BIN="/usr/local/sbin/haproxy"

        if [ ! -f /lib/systemd/system/haproxy.service ] && [ ! -f /etc/systemd/system/haproxy.service ]; then
            cat <<EOF_UNIT > /etc/systemd/system/haproxy.service
[Unit]
Description=HAProxy Load Balancer
After=network.target

[Service]
Type=simple
ExecStart=$HAP_BIN -f /etc/haproxy/haproxy.cfg -db
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
        fi

        systemctl daemon-reload >/dev/null 2>&1
        systemctl unmask haproxy >/dev/null 2>&1
        systemctl enable haproxy >/dev/null 2>&1
        systemctl restart haproxy >/dev/null 2>&1 || true
    ) &
    local p_pid=$!
    draw_progress_bar "$p_pid" "Deploying HAProxy Engine"
    wait "$p_pid"
}

get_iface_for_ip() {
    local target_ip=$1
    local subnet=$(echo "$target_ip" | cut -d'.' -f1-3)
    local iface=$(ip -o -4 addr show 2>/dev/null | grep -w "${subnet}\." | awk '{print $2}' | head -n 1)
    if [ -z "$iface" ]; then echo "Unknown"; else echo "$iface"; fi
}

get_stats() {
    server_ip=$(get_local_ip)
    if systemctl is-active --quiet haproxy; then hap_stat="${G}●${NC}"; raw_hap="●"; else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi
    
    local h_ports=0
    if [ -f "$H_CONF" ]; then h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--)); [ "$h_ports" -lt 0 ] && h_ports=0; fi
    total_ports=$h_ports

    local h_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    
    local all_ips=$(echo -e "$h_ips" | grep -v '^$' | sort -u)
    mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"
    else ip_status="${DIM}NONE${NC}"; raw_ip="NONE"; fi
}

draw_header() {
    get_stats; clear; echo ""
    raw_text=" MPorter 7.7.0 │ IP: $server_ip │ HAProxy: $raw_hap │ IPs: $raw_ip │ Pts: $total_ports "
    pad_len=$(( 92 - ${#raw_text} ))
    if (( pad_len < 0 )); then pad_len=0; fi
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter 7.7.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${server_ip}${NC} ${B}│${NC} ${DIM}HAProxy:${NC} ${hap_stat} ${B}│${NC} ${DIM}IPs:${NC} ${ip_status} ${B}│${NC} ${DIM}Pts:${NC} ${G}${total_ports}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}├──────────────┬────────────────────────────────────────────┬────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-30s${NC} ${B}│${NC}\n" "INTERFACE" "TARGET NETWORK IPs" "TOTAL FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼────────────────────────────────┤${NC}"
    
    local h_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E 'server srv_[0-9_]+ [0-9\.]+|server srv_[0-9]+ [0-9\.]+' "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    
    local ip_port_counts=$(echo -e "$h_map" | grep -v '^$' | awk -F'|' '{a[$1]+=$2} END {for (i in a) print i"|"a[i]}')

    if [ -z "$ip_port_counts" ] || [ "$ip_port_counts" == "|" ]; then
        printf "  ${B}│${NC} ${DIM}%-88s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A iface_ips_arr; declare -A iface_ports_arr
        while IFS='|' read -r ip count; do
            if [ -n "$ip" ]; then
                iface=$(get_iface_for_ip "$ip")
                iface_ips_arr["$iface"]+="$ip "
                iface_ports_arr["$iface"]=$(( iface_ports_arr["$iface"] + count ))
            fi
        done <<< "$ip_port_counts"
        for iface in $(for i in "${!iface_ips_arr[@]}"; do echo $i; done | sort); do
            ips=(${iface_ips_arr["$iface"]}); total_p=${iface_ports_arr["$iface"]}
            if [ ${#ips[@]} -gt 2 ]; then display_ips="${ips[0]}, ${ips[1]}, ..."
            elif [ ${#ips[@]} -eq 2 ]; then display_ips="${ips[0]}, ${ips[1]}"
            else display_ips="${ips[0]}"; fi
            
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${G}%-42s${NC} ${B}│${NC} ${Y}%-30s${NC} ${B}│${NC}\n" "$iface" "$display_ips" "$total_p Mapped"
        done
    fi
    echo -e "  ${B}╰──────────────┴────────────────────────────────────────────┴────────────────────────────────╯${NC}"
}

smart_map() {
    draw_header
    local active_ifs=()
    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && active_ifs+=($(grep -E "^T_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'")); done
    for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && active_ifs+=($(grep -E "^BR_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'")); done
    shopt -u nullglob

    local gre_ifs=()
    for iface in "${active_ifs[@]}"; do if ip link show "$iface" >/dev/null 2>&1; then gre_ifs+=("$iface"); fi; done

    local target_ip=""
    local selected_if=""
    local is_auto_all=false
    local selected_ips=()

    if [ ${#gre_ifs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No MDesign Tunnel interfaces found!${NC}"
        echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
        target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
        
        if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return
        fi
        selected_if="Manual"
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (Bypass Interfaces)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface (0-$(( ${#gre_ifs[@]} - 1 )) or 'm'): ${NC}"; read if_choice
        if_choice=$(echo "$if_choice" | tr -d '\r' | tr -d ' ')
        
        if [[ "$if_choice" == "m" ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
            target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
            
            if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return
            fi
            selected_if="Manual"
        elif [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -e "  ${R}● No active IPs found on ${selected_if}!${NC}"
                echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
                target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
                
                if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return
                fi
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                echo -e "  ${DIM}Tip: Enter 'a' to strictly auto-distribute ports across ALL IPs.${NC}"
                echo -ne "  ${C}●${NC} ${W}Select EXACT Index to process (0-$(( ${#map_ips[@]} - 1 ))) or 'a': ${NC}"; read ip_choice
                ip_choice=$(echo "$ip_choice" | tr -d '\r' | tr -d ' ')
                
                if [[ "$ip_choice" == "a" ]]; then
                    selected_ips=("${map_ips[@]}")
                    is_auto_all=true
                    echo -e "  ${G}✔ Auto-Distribute mode enabled for ${#selected_ips[@]} IPs.${NC}"
                elif [[ -n "${map_ips[$ip_choice]}" ]]; then 
                    local selected_local_ip="${map_ips[$ip_choice]}"
                    local base_ip=$(echo "$selected_local_ip" | cut -d'.' -f1-3); local last_octet=$(echo "$selected_local_ip" | cut -d'.' -f4)
                    local calc_target="${base_ip}.$((last_octet + 1))"
                    [ "$last_octet" == "1" ] && calc_target="${base_ip}.2"
                    [ "$last_octet" == "2" ] && calc_target="${base_ip}.1"
                    
                    echo -ne "\n  ${C}●${NC} ${W}Confirm Exact Target IP [${calc_target}]: ${NC}"; read custom_target
                    custom_target=$(echo "$custom_target" | tr -d '\r' | tr -d ' ')
                    target_ip="${custom_target:-$calc_target}"
                    
                    if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return
                    fi
                else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            fi
        else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
    fi

    if [ "$is_auto_all" != true ] && [ -z "$target_ip" ]; then echo -e "  ${R}● Target IP cannot be empty!${NC}"; sleep 1; return; fi

    echo -ne "\n  ${C}●${NC} ${W}Enter Exact Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports
    raw_ports=$(echo "$raw_ports" | tr -d '\r')
    if ! [[ "$raw_ports" =~ ^[0-9,]+$ ]]; then
        echo -e "  ${R}● Invalid port format! Use numbers and commas only.${NC}"; sleep 1.5; return
    fi
    
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    
    echo -e "\n  ${Y}● Applying Strict 1-to-1 Mappings (HAProxy)...${NC}"
    echo -e "  ${B}╭──────────────┬─────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Target IP"
    echo -e "  ${B}├──────────────┼─────────┼────────────────────────────────────────────┤${NC}"
    
    local port_idx=0
    for p in $clean_ports; do
        if [ "$is_auto_all" = true ]; then
            local selected_local_ip="${selected_ips[$((port_idx % ${#selected_ips[@]}))]}"
            local base_ip=$(echo "$selected_local_ip" | cut -d'.' -f1-3); local last_octet=$(echo "$selected_local_ip" | cut -d'.' -f4)
            target_ip="${base_ip}.$((last_octet + 1))"
            [ "$last_octet" == "1" ] && target_ip="${base_ip}.2"
            [ "$last_octet" == "2" ] && target_ip="${base_ip}.1"
        fi

        local skip_reason=""
        if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then skip_reason="OS/System"
        elif grep -q -w "frontend ft_$p" "$H_CONF" 2>/dev/null; then skip_reason="HAProxy"
        fi

        if [ -n "$skip_reason" ]; then
            printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "-" "Skipped (Used by $skip_reason)"
            continue
        fi
        
        (
            flock -x 200
            echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
        ) 200>/var/lock/mporter_haproxy.lock
        printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$target_ip"
        ((port_idx++))
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
    systemctl restart haproxy 2>/dev/null

    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read dummy
}

edit_mapping() {
    draw_header
    echo -e "\n  ${DIM}┌─[ EDIT FORWARDING MAPPINGS ]${NC}"
    local h_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    
    local all_ips=$(echo -e "$h_map" | grep -v '^$' | sort -u)
    if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi

    local ip_arr=($all_ips)
    echo -e "  ${B}╭────────────────── Select Target IP ──────────────────────╮${NC}"
    for i in "${!ip_arr[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${ip_arr[$i]}"; done
    echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}Select Index ❯❯ ${NC}"; read ip_idx
    ip_idx=$(echo "$ip_idx" | tr -d '\r' | tr -d ' ')

    local target_ip="${ip_arr[$ip_idx]}"
    if [ -z "$target_ip" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi

    while true; do
        draw_header
        local t_ports=""
        [ -f "$H_CONF" ] && t_ports+=$(grep "$target_ip:" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
        t_ports=$(echo "$t_ports" | tr ' ' '\n' | grep -v '^$' | sort -un | xargs)

        echo -e "\n  ${DIM}┌─[ EDITING: ${W}$target_ip${DIM} ]${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Active Ports:${NC} ${Y}${t_ports:-None}${NC}"
        echo -e "  ${DIM}├──────────────────────────────────────────────${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Add New Ports${NC} ${DIM}(Forward extra ports to this IP)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Remove Specific Ports${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Migrate Target IP${NC} ${DIM}(Move ports to a new IP)${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
        echo -ne "  ${C}Select Action ❯❯ ${NC}"; read edit_opt
        edit_opt=$(echo "$edit_opt" | tr -d '\r' | tr -d ' ')

        case $edit_opt in
            1) 
                echo -ne "\n  ${C}●${NC} ${W}Enter New Ports to Add (e.g. 80,443): ${NC}"; read raw_ports
                raw_ports=$(echo "$raw_ports" | tr -d '\r')
                if ! [[ "$raw_ports" =~ ^[0-9,]+$ ]]; then
                    echo -e "  ${R}● Invalid port format! Use numbers and commas only.${NC}"; sleep 1.5; continue
                fi
                clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
                
                for p in $clean_ports; do
                    if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then continue; fi
                    (
                        flock -x 200
                        echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
                    ) 200>/var/lock/mporter_haproxy.lock
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                systemctl restart haproxy 2>/dev/null
                echo -e "  ${G}● Ports added successfully!${NC}"; sleep 1.5 ;;
            2)
                echo -ne "\n  ${C}●${NC} ${W}Enter Exact Ports to Remove (e.g. 80,443): ${NC}"; read raw_ports
                raw_ports=$(echo "$raw_ports" | tr -d '\r')
                clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
                for p in $clean_ports; do
                    sed -i "/frontend ft_$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/bind \*:$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/default_backend bk_$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/backend bk_$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/server srv_$p /d" "$H_CONF" 2>/dev/null
                    sed -i "/server srv_${p}_[0-9]\+ /d" "$H_CONF" 2>/dev/null
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                systemctl restart haproxy 2>/dev/null
                echo -e "  ${G}● Ports removed securely!${NC}"; sleep 1.5 ;;
            3)
                echo -ne "\n  ${C}●${NC} ${W}Enter New Destination IP: ${NC}"; read new_ip
                new_ip=$(echo "$new_ip" | tr -d '\r' | tr -d ' ')
                if ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; continue
                fi
                echo -e "  ${DIM}● Migrating $target_ip -> $new_ip ...${NC}"
                
                if [ -f "$H_CONF" ]; then
                    sed -i "s/ $target_ip:/ $new_ip:/g" "$H_CONF"
                fi
                
                systemctl restart haproxy 2>/dev/null
                echo -e "  ${G}● IP Successfully Migrated!${NC}"; sleep 1.5
                target_ip="$new_ip"
                break
                ;;
            0) break ;; *) echo -e "  ${R}● Invalid selection!${NC}"; sleep 1 ;;
        esac
    done
}

show_table() {
    draw_header
    echo -e "\n  ${Y}● Detailed IP -> Port Matrix:${NC}"
    echo -e "  ${B}╭──────────────┬────────────────────────────────────────────┬────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-30s${NC} ${B}│${NC}\n" "INTERFACE" "TARGET IP" "FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼────────────────────────────────┤${NC}"
    
    local h_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | sed 's/:.*//')
    
    local mappings=$(echo -e "$h_map" | grep -v '^$')
    if [ -z "$mappings" ]; then printf "  ${B}│${NC} ${DIM}%-88s${NC} ${B}│${NC}\n" "  No active mappings."
    else
        declare -A ip_ports_arr
        while read -r p_num d_ip; do if [ -n "$d_ip" ]; then ip_ports_arr["$d_ip"]+="$p_num, "; fi; done <<< "$mappings"
        for d_ip in $(for i in "${!ip_ports_arr[@]}"; do echo $i; done | sort); do
            iface=$(get_iface_for_ip "$d_ip")
            raw_ports="${ip_ports_arr[$d_ip]}"; raw_ports="${raw_ports%, }"
            local clean_str="$raw_ports"
            if [ ${#clean_str} -gt 30 ]; then raw_ports="${clean_str:0:27}..."; clean_str="$raw_ports"; fi
            local pad=$(printf '%*s' "$((30 - ${#clean_str}))" "")
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${G}%-42s${NC} ${B}│${NC} ${Y}%s%s${NC} ${B}│${NC}\n" "$iface" "$d_ip" "$raw_ports" "$pad"
        done
    fi
    echo -e "  ${B}╰──────────────┴────────────────────────────────────────────┴────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

purge_menu() {
    draw_header
    echo -e "\n  ${DIM}┌─[ DELETE & PURGE MAPPINGS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${Y}Purge Specific Interface${NC} ${DIM}(Removes all IPs on an interface)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Purge Specific Target IP${NC} ${DIM}(Removes a single IP)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Wipe ALL Mappings Globally${NC} ${DIM}(Total Reset)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read p_opt
    p_opt=$(echo "$p_opt" | tr -d '\r' | tr -d ' ')
    
    local h_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    local all_ips=$(echo -e "$h_map" | grep -v '^$' | sort -u)

    case $p_opt in
        1)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            declare -A iface_ips
            for ip in $all_ips; do
                local iface=$(get_iface_for_ip "$ip")
                iface_ips["$iface"]+="$ip "
            done
            
            local i=0; local iface_list=()
            echo -e "\n  ${B}╭────────────────── Select Interface to Purge ─────────────────╮${NC}"
            for ifc in $(for key in "${!iface_ips[@]}"; do echo $key; done | sort); do
                iface_list[$i]="$ifc"
                local ip_arr=(${iface_ips[$ifc]})
                printf "  ${B}│${NC}  ${Y}%-2d${NC} ${C}❯${NC} ${W}%-15s${NC} ${DIM}(Contains %-2d IPs)${NC}                  ${B}│${NC}\n" "$i" "$ifc" "${#ip_arr[@]}"
                ((i++))
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx
            idx=$(echo "$idx" | tr -d '\r' | tr -d ' ')
            
            local selected_ifc="${iface_list[$idx]}"
            if [ -z "$selected_ifc" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            
            echo -ne "  ${Y}● Deep Purge ALL IPs on $selected_ifc? (y/n): ${NC}"; read conf
            conf=$(echo "$conf" | tr -d '\r' | tr -d ' ')
            if [[ "$conf" == "y" ]]; then
                for ip in ${iface_ips[$selected_ifc]}; do
                    purge_ip_core "$ip"
                done
                systemctl restart haproxy 2>/dev/null
                echo -e "  ${G}● Interface $selected_ifc purged successfully!${NC}"; sleep 1.5
            fi ;;
        2)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            local ip_arr=($all_ips)
            echo -e "\n  ${B}╭────────────────── Select Target IP to Purge ─────────────────╮${NC}"
            for i in "${!ip_arr[@]}"; do 
                local ifc=$(get_iface_for_ip "${ip_arr[$i]}")
                printf "  ${B}│${NC}  ${Y}%-2d${NC} ${C}❯${NC} ${W}%-15s${NC} ${DIM}(%s)${NC}                         ${B}│${NC}\n" "$i" "${ip_arr[$i]}" "$ifc"
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx
            idx=$(echo "$idx" | tr -d '\r' | tr -d ' ')
            
            local target_ip="${ip_arr[$idx]}"
            if [ -z "$target_ip" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            
            purge_ip_core "$target_ip"
            systemctl restart haproxy 2>/dev/null
            echo -e "  ${G}● IP $target_ip purged successfully!${NC}"; sleep 1.5 ;;
        3) 
            echo -ne "  ${R}● Wipe all active mappings globally? (y/n) ❯❯ ${NC}"; read confirm
            confirm=$(echo "$confirm" | tr -d '\r' | tr -d ' ')
            if [[ "$confirm" == "y" ]]; then
                echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
                echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
                systemctl restart haproxy 2>/dev/null
                echo -e "  ${G}● All global mappings wiped. Core configs preserved.${NC}"; sleep 1.5
            fi ;;
        0) return ;;
    esac
}

setup_watchdog() {
    cat <<'EOF_WD' > /usr/local/bin/mporter-watchdog.sh
#!/bin/bash
while true; do
    sleep 30
    /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1
done
EOF_WD
    chmod +x /usr/local/bin/mporter-watchdog.sh
    cat <<'EOF_WDS' > /etc/systemd/system/mporter-watchdog.service
[Unit]
Description=MPorter Smart Interface Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mporter-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_WDS
    systemctl daemon-reload; systemctl enable mporter-watchdog.service >/dev/null 2>&1; systemctl restart mporter-watchdog.service
}

smart_watchdog_menu() {
    draw_header
    local wd_stat="${R}OFFLINE${NC}"
    if systemctl is-active --quiet mporter-watchdog.service 2>/dev/null; then wd_stat="${G}ACTIVE${NC} ${DIM}(Scanning every 30s)${NC}"; fi

    echo -e "\n  ${DIM}┌─[ SMART INTERFACE WATCHDOG ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Status:${NC} ${wd_stat}"
    echo -e "  ${DIM}│${NC} ${DIM}Auto-deletes port mappings if their interface drops or is removed.${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Enable Watchdog${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Disable Watchdog${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    
    echo -ne "  ${C}Select ❯❯ ${NC}"; read wd_opt
    wd_opt=$(echo "$wd_opt" | tr -d '\r' | tr -d ' ')
    
    if [[ "$wd_opt" == "1" ]]; then
        setup_watchdog
        echo -e "  ${G}● Watchdog Enabled successfully!${NC}"; sleep 2
    elif [[ "$wd_opt" == "2" ]]; then
        systemctl stop mporter-watchdog 2>/dev/null; systemctl disable mporter-watchdog 2>/dev/null
        echo -e "  ${Y}● Watchdog Disabled.${NC}"; sleep 2
    fi
}

manual_restart() {
    draw_header
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read r_opt
    r_opt=$(echo "$r_opt" | tr -d '\r' | tr -d ' ')
    echo ""
    case $r_opt in
        1) systemctl restart haproxy 2>/dev/null; echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    sleep 1.5
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install & Configure HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Add Port Mappings (Strict 1-to-1)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Mappings (Add/Del/Migrate)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View IP -> Port Matrix${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Delete & Purge Mappings (By Interface/IP/All)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Uninstall HAProxy Setup${NC}\n  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Smart Interface Watchdog (Auto-Cleanup)${NC}\n  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Manual Restart HAProxy${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 30 opt
    opt=$(echo "$opt" | tr -d '\r' | tr -d ' ')
    case $opt in
        1) install_haproxy_core ;; 2) smart_map ;; 3) edit_mapping ;; 4) show_table ;;
        5) purge_menu ;;
        6) echo -ne "  ${R}● Wipe HAProxy Mappings? (y/n) ❯❯ ${NC}"; read confirm
           confirm=$(echo "$confirm" | tr -d '\r' | tr -d ' ')
           if [[ "$confirm" == "y" ]]; then 
               systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null
               systemctl stop mporter-watchdog 2>/dev/null; systemctl disable mporter-watchdog 2>/dev/null
               rm -rf /etc/haproxy /var/lib/haproxy /etc/systemd/system/mporter-watchdog.service
               apt-get purge -y haproxy 2>/dev/null; systemctl daemon-reload
               echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0
           fi ;;
        7) smart_watchdog_menu ;; 8) manual_restart ;; 0) clear; exit 0 ;;
    esac
done
