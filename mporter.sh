#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | HAProxy Manager v5.0.1 (Failover Audited) ---

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

install_haproxy_core() {
    echo -e "  ${C}●${NC} ${W}Configuring HAProxy Engine...${NC}"
    apt-get install -y haproxy socat >/dev/null 2>&1
    mkdir -p /etc/haproxy
    echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
    echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
    systemctl enable haproxy >/dev/null 2>&1; systemctl restart haproxy
}

install_gost_core() {
    echo -e "  ${M}●${NC} ${W}Configuring Gost Engine...${NC}"
    if [ ! -f /usr/local/bin/gost ]; then
        wget -qO gost.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gzip -d gost.gz; chmod +x gost; mv gost /usr/local/bin/gost
    fi
    mkdir -p /etc/gost
    if [ ! -f "$G_CONF" ] || ! jq . "$G_CONF" >/dev/null 2>&1; then echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"; fi
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
    systemctl daemon-reload; systemctl enable gost >/dev/null 2>&1; systemctl restart gost
}

fix_and_install() {
    echo -e "\n  ${DIM}┌─[ SELECT CORE ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Best for Load-Balancing)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} ${DIM}(Advanced Tunneling)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Both Cores${NC} ${DIM}(Dual-Core Setup)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Install ❯❯ ${NC}"; read -t 30 core_opt

    if [[ "$core_opt" =~ ^[1-3]$ ]]; then
        echo -e "\n  ${DIM}● Preparing OS & Dependencies...${NC}"
        sysctl -w fs.file-max=2000000 >/dev/null 2>&1
        rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock*
        dpkg --configure -a >/dev/null 2>&1 && apt-get install -f -y >/dev/null 2>&1
        apt-get update >/dev/null 2>&1
        apt-get install -y wget curl gzip jq iproute2 cron >/dev/null 2>&1
    fi
    case $core_opt in
        1) install_haproxy_core ;;
        2) install_gost_core ;;
        3) install_haproxy_core; install_gost_core ;;
        0) return ;;
        *) echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return ;;
    esac
    echo -e "  ${G}● Installation Completed Successfully.${NC}\n"; sleep 2
}

wipe_all_mappings() {
    if [ -f "$H_CONF" ]; then
        echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
        echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
        systemctl restart haproxy 2>/dev/null
    fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
        echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"; systemctl restart gost 2>/dev/null
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
    if systemctl is-active --quiet haproxy; then hap_stat="${G}●${NC}"; raw_hap="●"; else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi
    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"; else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    
    local h_ports=0; local g_ports=0
    if [ -f "$H_CONF" ]; then h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--)); [ "$h_ports" -lt 0 ] && h_ports=0; fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_ports=$(jq '.ServeNodes | length' "$G_CONF" 2>/dev/null); [ -z "$g_ports" ] && g_ports=0; fi
    total_ports=$((h_ports + g_ports))

    local h_ips=""; local g_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep "server srv_" "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d':' -f1)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_ips=$(jq -r '.ServeNodes[]' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:[0-9]+\/([0-9\.,:]+).*/\1/g' | tr ',' '\n' | cut -d':' -f1)
    
    local all_ips=$(echo -e "$h_ips\n$g_ips" | grep -v '^$' | sort -u)
    mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"
    else ip_status="${DIM}NONE${NC}"; raw_ip="NONE"; fi
}

draw_header() {
    get_stats; clear; echo ""
    raw_text=" MPorter 5.0.1 │ HOST: $server_ip │ HAProxy: $raw_hap │ Gost: $raw_gst │ IPs: $raw_ip │ PORTS: $total_ports"
    pad_len=$(( 93 - ${#raw_text} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭─────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter 5.0.1${NC} ${B}│${NC} ${DIM}HOST:${NC} ${W}${server_ip}${NC} ${B}│${NC} ${DIM}HAProxy:${NC} ${hap_stat} ${B}│${NC} ${DIM}Gost:${NC} ${gst_stat} ${B}│${NC} ${DIM}IPs:${NC} ${ip_status} ${B}│${NC} ${DIM}PORTS:${NC} ${G}${total_ports}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰─────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

smart_map() {
    draw_header
    echo -e "\n  ${DIM}┌─[ FORWARDING ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Supports Failover/LB)${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read fwd_engine
    
    if [ "$fwd_engine" != "1" ] && [ "$fwd_engine" != "2" ]; then echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; fi
    
    local is_lb=false
    echo -e "\n  ${DIM}┌─[ ROUTING MODE ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Single Target IP${NC} ${DIM}(Standard)${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Load-Balancing / Failover${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read route_mode
    if [ "$route_mode" == "2" ]; then is_lb=true; fi

    local gre_ifs=($(ls /sys/class/net 2>/dev/null | grep '^gre'))
    if [ ${#gre_ifs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No GRE interfaces found!${NC}"
        echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target IPs manually (comma-separated): ${NC}"; read manual_ip
        IFS=',' read -r -a selected_ips <<< "$manual_ip"; selected_if="Manual"
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (Bypass Interfaces)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface: ${NC}"; read if_choice
        
        if [[ "$if_choice" == "m" ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target IPs manually (comma-separated): ${NC}"; read manual_ip
            IFS=',' read -r -a selected_ips <<< "$manual_ip"; selected_if="Manual"
        elif [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -e "  ${R}● No IPs on ${selected_if}!${NC}"; return
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                
                if [ "$is_lb" = true ]; then
                    echo -e "  ${DIM}Tip: Enter 'a' for ALL IPs, or numbers separated by space (e.g., 0 2).${NC}"
                    echo -ne "  ${C}●${NC} ${W}Select Indexes: ${NC}"; read -a ip_choices
                    selected_ips=()
                    if [[ "${ip_choices[0]}" == "a" ]]; then selected_ips=("${map_ips[@]}")
                    else
                        for c in "${ip_choices[@]}"; do
                            [ -n "${map_ips[$c]}" ] && selected_ips+=("${map_ips[$c]}")
                        done
                    fi
                else
                    echo -e "  ${DIM}Tip: Enter 'a' to pick one random IP.${NC}"
                    echo -ne "  ${C}●${NC} ${W}Select Index (0-$(( ${#map_ips[@]} - 1 ))) or 'a': ${NC}"; read ip_choice
                    if [[ "$ip_choice" == "a" ]]; then selected_ips=("${map_ips[$((RANDOM % ${#map_ips[@]}))]}")
                    elif [[ -n "${map_ips[$ip_choice]}" ]]; then selected_ips=("${map_ips[$ip_choice]}")
                    else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
                fi
            fi
        else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
    fi

    if [ ${#selected_ips[@]} -eq 0 ]; then echo -e "  ${R}● No valid IPs selected.${NC}"; sleep 1.5; return; fi

    echo -ne "\n  ${C}●${NC} ${W}Enter Local Ports (e.g. 80,443): ${NC}"; read raw_ports
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    
    echo -e "\n  ${Y}● Applying Mappings (LB: $is_lb)...${NC}"
    echo -e "  ${B}╭──────────────┬─────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Target Nodes"
    echo -e "  ${B}├──────────────┼─────────┼────────────────────────────────────────────┤${NC}"
    
    for p in $clean_ports; do
        local target_list=()
        for sip in "${selected_ips[@]}"; do
            if [[ "$selected_if" == "Manual" ]]; then target_list+=("$sip")
            else
                local base_ip=$(echo "$sip" | cut -d'.' -f1-3)
                local last_octet=$(echo "$sip" | cut -d'.' -f4)
                target_list+=("${base_ip}.$([ "$last_octet" == "1" ] && echo "2" || echo "1")")
            fi
        done

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
        
        local disp_targets="${target_list[0]}"
        [ ${#target_list[@]} -gt 1 ] && disp_targets="${#target_list[@]} Nodes (LB Active)"

        if [ "$fwd_engine" == "1" ]; then
            echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p" >> "$H_CONF"
            [ "$is_lb" = true ] && echo "    balance roundrobin" >> "$H_CONF"
            
            local c=1
            for tip in "${target_list[@]}"; do
                echo "    server srv_${p}_${c} $tip:$p check inter 3000 rise 2 fall 3" >> "$H_CONF"
                ((c++))
            done
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$disp_targets"
        elif [ "$fwd_engine" == "2" ]; then
            local g_targets=""
            for tip in "${target_list[@]}"; do g_targets="${g_targets}${tip}:$p,"; done
            g_targets="${g_targets%,}"
            jq --arg node "tcp://:$p/$g_targets" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Gost" "$disp_targets"
        fi
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"
    
    [ "$fwd_engine" == "1" ] && systemctl restart haproxy 2>/dev/null
    [ "$fwd_engine" == "2" ] && systemctl restart gost 2>/dev/null
    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read
}

show_table() {
    draw_header
    echo -e "\n  ${Y}● Live Engine Matrix (Including Load-Balanced Nodes):${NC}"
    echo -e "  ${B}╭──────────────┬────────────────────────────────────────────┬─────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-31s${NC} ${B}│${NC}\n" "PORT" "TARGET NODES (DESTINATION)" "ENGINE"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼─────────────────────────────────┤${NC}"
    
    local has_data=false
    if [ -f "$H_CONF" ]; then
        # تفکیک پورت‌ها با فیلتر sort -u جهت جلوگیری از تکرار فیلدها در جدول رندر
        local h_ports=$(grep "frontend ft_" "$H_CONF" | awk -F'_' '{print $2}' | sort -u)
        for p in $h_ports; do
            local targets=$(grep "server srv_${p}_" "$H_CONF" | awk '{print $3}' | cut -d':' -f1 | paste -sd ", " -)
            if [ ${#targets} -gt 40 ]; then targets="${targets:0:37}..."; fi
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-42s${NC} ${B}│${NC} ${DIM}%-31s${NC} ${B}│${NC}\n" "$p" "$targets" "HAProxy"
            has_data=true
        done
    fi
    
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
        local g_nodes=$(jq -r '.ServeNodes[]' "$G_CONF" 2>/dev/null)
        for node in $g_nodes; do
            local p=$(echo "$node" | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/')
            local targets=$(echo "$node" | sed -E 's/.*\/([0-9\.,:]+)/\1/' | tr ',' ' ' | sed 's/:[0-9]*//g' | tr ' ' ',')
            if [ ${#targets} -gt 40 ]; then targets="${targets:0:37}..."; fi
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-42s${NC} ${B}│${NC} ${DIM}%-31s${NC} ${B}│${NC}\n" "$p" "$targets" "Gost"
            has_data=true
        done
    fi
    
    if [ "$has_data" = false ]; then
        printf "  ${B}│${NC} ${DIM}%-89s${NC} ${B}│${NC}\n" "  No active mappings."
    fi
    echo -e "  ${B}╰──────────────┴────────────────────────────────────────────┴─────────────────────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

while true; do
    draw_header; echo ""
    echo -e "  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install & Configure Core Engines${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Add Port Mappings (Failover/LB Mode)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}View Node Matrix & Ports${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Wipe All Mappings${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Auto-Restart Scheduler (Cron)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Manual Restart Services${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 60 opt
    case $opt in
        1) fix_and_install ;;
        2) smart_map ;;
        3) show_table ;;
        4) echo -ne "  ${Y}● Wipe all active mappings? (y/n) ❯❯ ${NC}"; read confirm; [[ "$confirm" == "y" ]] && wipe_all_mappings ;;
        5) auto_restart_cron ;;
        6) systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; echo -e "\n  ${G}● Services restarted.${NC}"; sleep 1.5 ;;
        0) clear; exit 0 ;;
    esac
done
