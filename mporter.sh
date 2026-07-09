#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v4.3.1 (Stable UI) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

INSTALL_PATH="/usr/bin/mporter"
H_CONF="/etc/haproxy/haproxy.cfg"
G_CONF="/etc/gost/config.json"

if [[ "$1" != "--apply" ]]; then
    if [[ ! -x "$INSTALL_PATH" ]]; then cp "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null; fi
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

# ---------------------------------------------------------
# MDesign Animated Progress Bar Engine (ASCII Stable)
# ---------------------------------------------------------
draw_progress_bar() {
    local pid=$1
    local text=$2
    local width=25
    local progress=0
    
    tput civis # Hide cursor
    
    while kill -0 $pid 2>/dev/null; do
        progress=$((progress + 1))
        [ $progress -gt 95 ] && progress=95
        
        local filled=$(( progress * width / 100 ))
        local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" | tr ' ' '#')
        local empty_bar=$(printf "%${empty}s" | tr ' ' '-')
        
        printf "\r  ${C}⟳${NC} ${W}%-22s${NC} ${M}[${bar}${DIM}${empty_bar}${M}]${NC} ${C}%3d%%${NC}" "$text" "$progress"
        sleep 0.2
    done
    
    local bar=$(printf "%${width}s" | tr ' ' '#')
    printf "\r  ${G}✔${NC} ${W}%-22s${NC} ${G}[${bar}]${NC} ${G}100%%${NC} \n" "$text"
    
    tput cnorm # Restore cursor
}
# ---------------------------------------------------------

install_haproxy_core() {
    (
        apt-get install -y haproxy socat >/dev/null 2>&1
        mkdir -p /etc/haproxy
        echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
        echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
        systemctl enable haproxy >/dev/null 2>&1
        systemctl restart haproxy >/dev/null 2>&1
    ) &
    draw_progress_bar $! "Deploying HAProxy"
}

install_gost_core() {
    (
        if [ ! -f /usr/local/bin/gost ]; then
            wget -qO gost.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz >/dev/null 2>&1
            gzip -d gost.gz; chmod +x gost; mv gost /usr/local/bin/gost
        fi
        mkdir -p /etc/gost
        if [ ! -f "$G_CONF" ] || ! jq . "$G_CONF" >/dev/null 2>&1; then
            echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
        fi

cat <<EOF > /etc/systemd/system/gost.service
[Unit]
Description=GO Simple Tunnel (MPorter Core)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable gost >/dev/null 2>&1; systemctl restart gost >/dev/null 2>&1
    ) &
    draw_progress_bar $! "Deploying Gost Tunnel"
}

fix_and_install() {
    echo -e "\n  ${DIM}┌─[ SELECT CORE ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Standard Multiplexer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} ${DIM}(Advanced Tunneling)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Both Cores${NC} ${DIM}(Dual-Core Setup)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo ""
    echo -ne "  ${C}Install ❯❯ ${NC}"; read -t 30 core_opt

    if [[ "$core_opt" =~ ^[1-3]$ ]]; then
        echo ""
        (
            sysctl -w fs.file-max=2000000 >/dev/null 2>&1
            rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock*
            dpkg --configure -a >/dev/null 2>&1 && apt-get install -f -y >/dev/null 2>&1
            apt-get update >/dev/null 2>&1
            apt-get install -y wget curl gzip jq iproute2 cron socat >/dev/null 2>&1
        ) &
        draw_progress_bar $! "Preparing OS & Deps"
    fi

    case $core_opt in
        1) install_haproxy_core ;;
        2) install_gost_core ;;
        3) install_haproxy_core; install_gost_core ;;
        0) return ;;
        *) echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return ;;
    esac
    echo -e "\n  ${G}● Initialization Completed Successfully.${NC}"; sleep 2
}

wipe_all_mappings() {
    if [ -f "$H_CONF" ]; then
        echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
        echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
        systemctl restart haproxy 2>/dev/null
    fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
        echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
        systemctl restart gost 2>/dev/null
    fi
    echo -e "  ${G}● All Engine Mappings Wiped Clean.${NC}"; sleep 1.5
}

get_iface_for_ip() {
    local target_ip=$1
    local subnet=$(echo "$target_ip" | cut -d'.' -f1-3)
    local iface=$(ip -o -4 addr show 2>/dev/null | grep "$subnet" | awk '{print $2}' | head -n 1)
    if [ -z "$iface" ]; then echo "Unknown"; else echo "$iface"; fi
}

get_stats() {
    server_ip=$(get_local_ip)
    if systemctl is-active --quiet haproxy; then hap_stat="${G}●${NC}"; raw_hap="●"
    else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi

    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"
    else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    
    local h_ports=0; local g_ports=0
    if [ -f "$H_CONF" ]; then
        h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--))
        [ "$h_ports" -lt 0 ] && h_ports=0
    fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
        g_ports=$(jq '.ServeNodes | length' "$G_CONF" 2>/dev/null); [ -z "$g_ports" ] && g_ports=0
    fi
    total_ports=$((h_ports + g_ports))

    local h_ips=""; local g_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep "server srv_" "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d':' -f1)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_ips=$(jq -r '.ServeNodes[]' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:[0-9]+\/([0-9\.]+):.*/\1/g')
    
    local all_ips=$(echo -e "$h_ips\n$g_ips" | grep -v '^$' | sort -u)
    mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"
    else ip_status="${DIM}NONE${NC}"; raw_ip="NONE"; fi
}

draw_header() {
    get_stats; clear; echo ""
    raw_text=" MPorter 4.3.1 │ HOST: $server_ip │ HAProxy: $raw_hap │ Gost: $raw_gst │ IPs: $raw_ip │ PORTS: $total_ports"
    pad_len=$(( 93 - ${#raw_text} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭─────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter 4.3.1${NC} ${B}│${NC} ${DIM}HOST:${NC} ${W}${server_ip}${NC} ${B}│${NC} ${DIM}HAProxy:${NC} ${hap_stat} ${B}│${NC} ${DIM}Gost:${NC} ${gst_stat} ${B}│${NC} ${DIM}IPs:${NC} ${ip_status} ${B}│${NC} ${DIM}PORTS:${NC} ${G}${total_ports}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}├──────────────┬────────────────────────────────────────────┬─────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-31s${NC} ${B}│${NC}\n" "INTERFACE" "TARGET NETWORK IPs" "TOTAL FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼─────────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""
    [ -f "$H_CONF" ] && h_map=$(grep "server srv_" "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d':' -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:[0-9]+\/([0-9\.]+):.*/\1/g' | sort | uniq -c | awk '{print $2 "|" $1}')
    
    local ip_port_counts=$(echo -e "$h_map\n$g_map" | grep -v '^$' | awk -F'|' '{a[$1]+=$2} END {for (i in a) print i"|"a[i]}')

    if [ -z "$ip_port_counts" ] || [ "$ip_port_counts" == "|" ]; then
        printf "  ${B}│${NC} ${DIM}%-89s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route."
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
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${G}%-42s${NC} ${B}│${NC} ${Y}%-31s${NC} ${B}│${NC}\n" "$iface" "$display_ips" "$total_p Ports Forwarding"
        done
    fi
    echo -e "  ${B}╰──────────────┴────────────────────────────────────────────┴─────────────────────────────────╯${NC}"
}

smart_map() {
    draw_header
    echo -e "\n  ${DIM}┌─[ FORWARDING ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read fwd_engine
    
    if [ "$fwd_engine" != "1" ] && [ "$fwd_engine" != "2" ]; then echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; fi
    if [ "$fwd_engine" == "2" ] && ! command -v jq >/dev/null 2>&1; then echo -e "  ${R}● Gost requires 'jq'. Run Installer (1) first.${NC}"; sleep 2; return; fi

    local gre_ifs=($(ls /sys/class/net 2>/dev/null | grep -E '^(gre|br_|wg)'))
    if [ ${#gre_ifs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No Tunnel interfaces found!${NC}"
        echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target IP manually: ${NC}"; read manual_ip; selected_ips=("$manual_ip"); selected_if="Manual"
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (Bypass Interfaces)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface (0-$(( ${#gre_ifs[@]} - 1 )) or 'm'): ${NC}"; read if_choice
        
        if [[ "$if_choice" == "m" ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target IP manually: ${NC}"; read manual_ip; selected_ips=("$manual_ip"); selected_if="Manual"
        elif [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -e "  ${R}● No active IPs found on ${selected_if}!${NC}"
                echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target IP manually: ${NC}"; read manual_ip; selected_ips=("$manual_ip"); selected_if="Manual"
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                echo -e "  ${DIM}Tip: Enter 'a' to randomize across all IPs.${NC}"
                echo -ne "  ${C}●${NC} ${W}Select Index (0-$(( ${#map_ips[@]} - 1 ))) or 'a': ${NC}"; read ip_choice
                
                if [[ "$ip_choice" == "a" ]]; then selected_ips=("${map_ips[@]}")
                elif [[ -n "${map_ips[$ip_choice]}" ]]; then selected_ips=("${map_ips[$ip_choice]}")
                else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            fi
        else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
    fi

    echo -ne "\n  ${C}●${NC} ${W}Enter Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    
    echo -e "\n  ${Y}● Applying Mappings...${NC}"
    echo -e "  ${B}╭──────────────┬─────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Assigned Target IP"
    echo -e "  ${B}├──────────────┼─────────┼────────────────────────────────────────────┤${NC}"
    
    for p in $clean_ports; do
        local selected_ip="${selected_ips[$((RANDOM % ${#selected_ips[@]}))]}"
        if [ -n "$manual_ip" ]; then 
            target_ip="$manual_ip"
        else
            local base_ip=$(echo "$selected_ip" | cut -d'.' -f1-3)
            local last_octet=$(echo "$selected_ip" | cut -d'.' -f4)
            target_ip="${base_ip}.$([ "$last_octet" == "1" ] && echo "2" || echo "1")"
        fi
        
        local skip_reason=""
        if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then skip_reason="OS/System"
        elif grep -q -w "frontend ft_$p" "$H_CONF" 2>/dev/null; then skip_reason="HAProxy"
        elif [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
            if jq -e ".ServeNodes[] | select(. | contains(\"tcp://:$p/\"))" "$G_CONF" >/dev/null 2>&1; then skip_reason="Gost"; fi
        fi

        if [ -n "$skip_reason" ]; then
            printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "-" "Skipped (Used by $skip_reason)"
            continue
        fi
        
        if [ "$fwd_engine" == "1" ]; then
            echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$target_ip (on $selected_if)"
        elif [ "$fwd_engine" == "2" ]; then
            jq --arg node "tcp://:$p/$target_ip:$p" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Gost" "$target_ip (on $selected_if)"
        fi
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"
    
    [ "$fwd_engine" == "1" ] && systemctl restart haproxy 2>/dev/null
    [ "$fwd_engine" == "2" ] && systemctl restart gost 2>/dev/null
    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read
}

show_table() {
    draw_header
    echo -e "\n  ${Y}● Detailed IP -> Port Matrix:${NC}"
    echo -e "  ${B}╭──────────────┬────────────────────────────────────────────┬─────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-31s${NC} ${B}│${NC}\n" "INTERFACE" "TARGET IP" "FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼─────────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | sed 's/:.*//')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/([0-9\.]+):.*/\1 \2/g')
    
    local mappings=$(echo -e "$h_map\n$g_map" | grep -v '^$')
    if [ -z "$mappings" ]; then 
        printf "  ${B}│${NC} ${DIM}%-89s${NC} ${B}│${NC}\n" "  No active mappings."
    else
        declare -A ip_ports_arr
        while read -r p_num d_ip; do
            if [ -n "$d_ip" ]; then ip_ports_arr["$d_ip"]+="$p_num, "; fi
        done <<< "$mappings"
        for d_ip in $(for i in "${!ip_ports_arr[@]}"; do echo $i; done | sort); do
            iface=$(get_iface_for_ip "$d_ip")
            ports="${ip_ports_arr[$d_ip]}"; ports="${ports%, }"
            if [ ${#ports} -gt 31 ]; then ports="${ports:0:28}..."; fi
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${G}%-42s${NC} ${B}│${NC} ${Y}%-31s${NC} ${B}│${NC}\n" "$iface" "$d_ip" "$ports"
        done
    fi
    echo -e "  ${B}╰──────────────┴────────────────────────────────────────────┴─────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

auto_restart_cron() {
    draw_header
    echo -e "\n  ${DIM}┌─[ AUTO-RESTART SCHEDULER ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Set interval for automatic core restarts.${NC}"
    echo -e "  ${DIM}│${NC} ${DIM}Enter '0' for both to disable the scheduler.${NC}"
    echo -ne "  ${DIM}├─${NC} ${C}Every X Hours (0-23) ❯❯ ${NC}"; read cron_h
    echo -ne "  ${DIM}└─${NC} ${C}Every X Minutes (0-59) ❯❯ ${NC}"; read cron_m

    if ! [[ "$cron_h" =~ ^[0-9]+$ ]] || ! [[ "$cron_m" =~ ^[0-9]+$ ]]; then
        echo -e "\n  ${R}● Invalid input! Numbers only.${NC}"; sleep 2; return
    fi

    crontab -l 2>/dev/null | grep -v "systemctl restart haproxy.*gost" | crontab - 2>/dev/null

    if [ "$cron_h" == "0" ] && [ "$cron_m" == "0" ]; then
        echo -e "\n  ${Y}● Auto-restart disabled. System returned to normal.${NC}"
    else
        local h_str="*"; local m_str="*"
        [ "$cron_h" -gt 0 ] && h_str="*/$cron_h"
        [ "$cron_m" -gt 0 ] && m_str="*/$cron_m"
        [ "$cron_h" -gt 0 ] && [ "$cron_m" == "0" ] && m_str="0"

        (crontab -l 2>/dev/null; echo "$m_str $h_str * * * systemctl restart haproxy >/dev/null 2>&1; systemctl restart gost >/dev/null 2>&1") | crontab - 2>/dev/null
        echo -e "\n  ${G}● Auto-restart configured! (Cron Format: $m_str $h_str * * *)${NC}"
    fi
    sleep 2
}

manual_restart() {
    draw_header
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Restart Gost Engine${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Restart Both Engines${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo ""
    echo -ne "  ${C}Select ❯❯ ${NC}"; read r_opt
    
    echo ""
    case $r_opt in
        1) systemctl restart haproxy 2>/dev/null; echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        2) systemctl restart gost 2>/dev/null; echo -e "  ${G}● Gost restarted successfully.${NC}" ;;
        3) systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; echo -e "  ${G}● Both engines restarted successfully.${NC}" ;;
        0) return ;;
        *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    sleep 1.5
}

while true; do
    draw_header
    echo ""
    echo -e "  ${DIM}┌─[ ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install & Configure Core Engines${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Add Port Mappings (Multipoint)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Activate Dynamic Sync${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Wipe Mappings (Standard Reset)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}View IP -> Port Matrix${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Uninstall Everything (Nuclear Wipe)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${M}Auto-Restart Scheduler (Cron)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Manual Restart Services${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}"
    echo ""
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 30 opt
    case $opt in
        1) fix_and_install ;;
        2) smart_map ;;
        3) echo -e "  ${G}● Dynamic Sync active.${NC}"; sleep 1 ;;
        4) 
            echo -ne "  ${Y}● Wipe all active mappings? (y/n) ❯❯ ${NC}"; read confirm
            if [[ "$confirm" == "y" ]]; then wipe_all_mappings; fi
            ;;
        5) show_table ;;
        6) 
            echo -ne "  ${R}● Nuclear Wipe? (y/n) ❯❯ ${NC}"; read confirm
            if [[ "$confirm" == "y" ]]; then 
                systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null
                systemctl stop gost 2>/dev/null; systemctl disable gost 2>/dev/null
                crontab -l 2>/dev/null | grep -v "systemctl restart haproxy.*gost" | crontab - 2>/dev/null
                rm -rf /etc/haproxy /var/lib/haproxy /usr/local/bin/gost /etc/gost /etc/systemd/system/gost.service
                apt-get purge -y haproxy 2>/dev/null; systemctl daemon-reload
                echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0
            fi ;;
        7) auto_restart_cron ;;
        8) manual_restart ;;
        0) clear; exit 0 ;;
    esac
done
