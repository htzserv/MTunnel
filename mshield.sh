cat << 'EOF_MSHIELD' > /usr/bin/mshield
#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Zero-Trust & Auto-Sync OBFS v2.2.2 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

OBFS_DIR="/etc/mshield/obfs"
SYNC_CONF="/etc/mshield/sync.conf"
OBFS_SVC="/etc/systemd/system/mshield-obfs.service"
SYNC_SVC="/etc/systemd/system/mshield-sync.service"

mkdir -p "$OBFS_DIR" 2>/dev/null

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    
    local fw_stat="${DIM}OFFLINE${NC}"
    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then fw_stat="${G}ACTIVE${NC}"; fi
    
    local obfs_stat="${DIM}OFFLINE${NC}"
    if systemctl is-active --quiet mshield-obfs.service 2>/dev/null; then obfs_stat="${C}ACTIVE${NC}"; fi
    if systemctl is-active --quiet mshield-sync.service 2>/dev/null; then obfs_stat="${M}AUTO-SYNC${NC}"; fi

    clear; echo ""
    local str1=" MShield Zero-Trust & Auto-Sync 2.2.2 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} Firewall:${NC} ${fw_stat} ${DIM}│ OBFS:${NC} ${obfs_stat} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# ==========================================
# 1. ZERO-TRUST FIREWALL ENGINE
# ==========================================
activate_firewall() {
    echo -e "\n  ${DIM}● Scanning MDesign ecosystem for active configurations...${NC}"
    
    iptables -D INPUT -j MSHIELD >/dev/null 2>&1
    iptables -F MSHIELD >/dev/null 2>&1; iptables -X MSHIELD >/dev/null 2>&1
    iptables -N MSHIELD

    iptables -A MSHIELD -i lo -j ACCEPT
    iptables -A MSHIELD -m state --state RELATED,ESTABLISHED -j ACCEPT

    local ssh_port=$(ss -tlnp 2>/dev/null | grep -i sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -n 1)
    [ -z "$ssh_port" ] && ssh_port=22
    iptables -A MSHIELD -p tcp --dport "$ssh_port" -j ACCEPT
    echo -e "  ${G}✔${NC} Secured SSH Management Port (${ssh_port})"

    local peer_ips=""
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do 
        if [ -f "$conf" ]; then
            local r_ip=$(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$conf" | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.)' | head -n 1)
            [ -n "$r_ip" ] && peer_ips="$peer_ips $r_ip\n"
        fi
    done
    if [ -n "$peer_ips" ]; then
        local unique_peers=$(echo -e "$peer_ips" | sort -u | grep -v '^$')
        for pip in $unique_peers; do
            iptables -A MSHIELD -s "$pip" -j ACCEPT
            echo -e "  ${G}✔${NC} Whitelisted Core Peer IP: ${C}$pip${NC}"
        done
    fi

    local fw_ports=""
    [ -f "/etc/haproxy/haproxy.cfg" ] && fw_ports+=$(awk '/frontend ft_/ {print $2}' /etc/haproxy/haproxy.cfg | sed 's/ft_//')"\n"
    [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1 && fw_ports+=$(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g')"\n"
    
    shopt -s nullglob
    for conf in "$OBFS_DIR"/*.conf; do
        if [ -f "$conf" ]; then
            local obfs_p=$(grep -oP '://:\K[0-9]+' "$conf" | head -n 1)
            [ -n "$obfs_p" ] && fw_ports+="${obfs_p}\n"
        fi
    done
    shopt -u nullglob

    if [ -n "$fw_ports" ]; then
        local unique_ports=$(echo -e "$fw_ports" | sort -n -u | grep -v '^$')
        for port in $unique_ports; do
            iptables -A MSHIELD -p tcp --dport "$port" --syn -m limit --limit 25/s --limit-burst 100 -j ACCEPT
            iptables -A MSHIELD -p tcp --dport "$port" --syn -j DROP
            iptables -A MSHIELD -p tcp --dport "$port" -j ACCEPT
        done
        echo -e "  ${G}✔${NC} Secured MPorter & OBFS ports with SYN-Flood protection."
    fi

    iptables -A MSHIELD -p gre -j DROP
    iptables -A MSHIELD -p udp --dport 4789 -j DROP
    iptables -A MSHIELD -p tcp -m tcp --dport 1:65535 --tcp-flags SYN,RST,ACK SYN -m recent --name M_SCANNER --set -j ACCEPT
    iptables -A MSHIELD -m recent --name M_SCANNER --rcheck --seconds 3600 --hitcount 8 -j DROP
    iptables -A MSHIELD -p icmp --icmp-type echo-request -j DROP

    iptables -I INPUT 1 -j MSHIELD
    echo -e "\n  ${G}● Zero-Trust Shield Activated Successfully!${NC}"; sleep 2
}

disable_firewall() {
    echo -e "\n  ${Y}● Disarming network defense lines...${NC}"
    while iptables -D INPUT -j MSHIELD >/dev/null 2>&1; do :; done
    iptables -F MSHIELD 2>/dev/null; iptables -X MSHIELD 2>/dev/null
    echo -e "  ${G}● Firewall deactivated. Standard WAN probing allowed.${NC}"; sleep 1.5
}

# ==========================================
# 2. SMART OBFS ENGINE (MPORTER SYNC DAEMON)
# ==========================================
install_gost_if_needed() {
    if ! command -v gost >/dev/null 2>&1; then
        echo -e "  ${Y}● Gost Engine not found. Installing OBFS core...${NC}"
        wget -qO gost.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz >/dev/null 2>&1
        gzip -d gost.gz; chmod +x gost; mv gost /usr/local/bin/gost
    fi
}

deploy_sync_daemon() {
    cat <<'EOF' > /usr/local/bin/mshield-sync-daemon.sh
#!/bin/bash
while true; do
    if [ ! -f "/etc/mshield/sync.conf" ]; then sleep 60; continue; fi

    declare -A target_tcp_ports
    declare -A target_udp_ports

    if [ -f "/etc/haproxy/haproxy.cfg" ]; then
        while read -r p t; do
            t_ip=$(echo "$t" | cut -d: -f1)
            t_port=$(echo "$t" | cut -d: -f2)
            target_tcp_ports["$t_ip"]+="$t_port "
        done < <(awk '/server srv_/ {print $2 " " $3}' /etc/haproxy/haproxy.cfg 2>/dev/null | sed 's/srv_//')
    fi

    if [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1; then
        while read -r raw; do
            proto=$(echo "$raw" | grep -oE '^(tcp|udp)')
            t_ip=$(echo "$raw" | sed -E 's/.*\/\/:[0-9]+\/([0-9\.]+):[0-9]+.*/\1/')
            t_port=$(echo "$raw" | sed -E 's/.*\/\/:[0-9]+\/[0-9\.]+:([0-9]+).*/\1/')
            if [ "$proto" == "tcp" ]; then target_tcp_ports["$t_ip"]+="$t_port "
            elif [ "$proto" == "udp" ]; then target_udp_ports["$t_ip"]+="$t_port "; fi
        done < <(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null)
    fi

    iptables -t nat -S OUTPUT 2>/dev/null | grep "MSHIELD_SYNC" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
    rm -f /etc/mshield/obfs/client_*.conf

    while IFS='|' read -r sync_ip remote_pub stealth_port method; do
        [ -z "$sync_ip" ] && continue

        tcp_ports=$(echo "${target_tcp_ports[$sync_ip]}" | tr ' ' '\n' | sort -u | grep -v '^$')
        udp_ports=$(echo "${target_udp_ports[$sync_ip]}" | tr ' ' '\n' | sort -u | grep -v '^$')

        for p in $tcp_ports; do
            local_port=$((30000 + p))
            iptables -t nat -A OUTPUT -p tcp -d "$sync_ip" --dport "$p" -m comment --comment "MSHIELD_SYNC" -j REDIRECT --to-ports "$local_port"
            echo "/usr/local/bin/gost -L tcp://:$local_port/$sync_ip:$p -F $method://$remote_pub:$stealth_port" > /etc/mshield/obfs/client_${sync_ip}_${p}_tcp.conf
        done

        for p in $udp_ports; do
            local_port=$((40000 + p))
            iptables -t nat -A OUTPUT -p udp -d "$sync_ip" --dport "$p" -m comment --comment "MSHIELD_SYNC" -j REDIRECT --to-ports "$local_port"
            echo "/usr/local/bin/gost -L udp://:$local_port/$sync_ip:$p -F $method://$remote_pub:$stealth_port" > /etc/mshield/obfs/client_${sync_ip}_${p}_udp.conf
        done
    done < "/etc/mshield/sync.conf"

    NEW_HASH=$(cat /etc/mshield/obfs/client_*.conf 2>/dev/null | md5sum | awk '{print $1}')
    OLD_HASH=$(cat /tmp/mshield_obfs_hash 2>/dev/null)
    if [ "$NEW_HASH" != "$OLD_HASH" ]; then
        cat <<'RUNNER' > /usr/local/bin/mshield-runner.sh
#!/bin/bash
while true; do
$(for conf in /etc/mshield/obfs/*.conf; do [ -f "$conf" ] && echo "$(cat "$conf") &"; done)
wait
done
RUNNER
        chmod +x /usr/local/bin/mshield-runner.sh
        systemctl restart mshield-obfs.service 2>/dev/null
        echo "$NEW_HASH" > /tmp/mshield_obfs_hash
    fi

    sleep 60
done
EOF
    chmod +x /usr/local/bin/mshield-sync-daemon.sh

    cat <<EOF > "$SYNC_SVC"
[Unit]
Description=MShield MPorter Auto-Sync Daemon
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mshield-sync-daemon.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    
    cat <<EOF > "$OBFS_SVC"
[Unit]
Description=MShield OBFS Stealth Transport
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mshield-runner.sh
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mshield-obfs >/dev/null 2>&1
    systemctl enable mshield-sync >/dev/null 2>&1
    systemctl restart mshield-sync
}

smart_obfs_deploy() {
    install_gost_if_needed
    echo -e "\n  ${DIM}┌─[ SMART OBFS DEPLOYMENT ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}SERVER Mode (Exit Node / Kharej)${NC} ${DIM}- Standard Universal Receiver${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}CLIENT Mode (Entry Node / Iran)${NC}  ${DIM}- MPorter Auto-Sync Daemon${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read o_mode
    
    [[ "$o_mode" != "1" && "$o_mode" != "2" ]] && return

    echo -ne "\n  ${C}●${NC} ${W}Select Transport Protocol [1: TLS | 2: Websocket (WS) | 3: WSS]: ${NC}"; read t_proto
    local method="relay+tls"
    [ "$t_proto" == "2" ] && method="relay+ws"
    [ "$t_proto" == "3" ] && method="relay+wss"

    if [ "$o_mode" == "1" ]; then
        echo -ne "  ${C}●${NC} ${W}Enter Universal Stealth Port to listen on (e.g. 8443): ${NC}"; read s_port
        [ -z "$s_port" ] && return
        
        local cmd="/usr/local/bin/gost -L $method://:$s_port"
        echo "$cmd" > "$OBFS_DIR/server_main.conf"
        
        cat <<EOF > /usr/local/bin/mshield-runner.sh
#!/bin/bash
while true; do
$cmd &
wait
done
EOF
        chmod +x /usr/local/bin/mshield-runner.sh
        
        cat <<EOF > "$OBFS_SVC"
[Unit]
Description=MShield OBFS Stealth Transport
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mshield-runner.sh
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable mshield-obfs >/dev/null 2>&1; systemctl restart mshield-obfs
        echo -e "\n  ${G}● Server OBFS Universal Receiver created! Listening on :${s_port}${NC}"
    
    elif [ "$o_mode" == "2" ]; then
        declare -a mp_ips
        
        if [ -f "/etc/haproxy/haproxy.cfg" ]; then
            while read -r t; do mp_ips+=("$(echo "$t" | cut -d: -f1)"); done < <(awk '/server srv_/ {print $3}' /etc/haproxy/haproxy.cfg 2>/dev/null)
        fi
        if [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1; then
            while read -r raw; do mp_ips+=("$(echo "$raw" | sed -E 's/.*\/\/:[0-9]+\/([0-9\.]+):[0-9]+.*/\1/')"); done < <(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null)
        fi

        local unique_ips=($(echo "${mp_ips[@]}" | tr ' ' '\n' | sort -u | grep -v '^$'))
        
        if [ ${#unique_ips[@]} -gt 0 ]; then
            echo -e "\n  ${B}╭─── Discovered MPorter Target Networks ───╮${NC}"
            for i in "${!unique_ips[@]}"; do
                printf "  ${B}│${NC}  ${Y}%-2s${NC} ${C}❯${NC} ${W}Virtual IP Group: %-16s${NC} ${B}│${NC}\n" "$i" "${unique_ips[$i]}"
            done
            echo -e "  ${B}╰──────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}●${NC} ${W}Select Virtual IP Group to Auto-Sync (0-$(( ${#unique_ips[@]} - 1 ))): ${NC}"; read r_sel
            
            if [[ -n "${unique_ips[$r_sel]}" ]]; then
                target_ip="${unique_ips[$r_sel]}"
                echo -e "  ${G}✔ Selected Target: ${target_ip}${NC}"
            else
                echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return
            fi
        else
            echo -e "\n  ${R}● No active MPorter forwarding rules found! Run MPorter first.${NC}"; sleep 2; return
        fi

        echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP: ${NC}"; read r_ip
        echo -ne "  ${C}●${NC} ${W}Enter Kharej Server STEALTH PORT (The one you set in Step 1): ${NC}"; read r_port
        [ -z "$r_ip" ] || [ -z "$r_port" ] && return
        
        echo "${target_ip}|${r_ip}|${r_port}|${method}" >> "$SYNC_CONF"
        sort -u "$SYNC_CONF" -o "$SYNC_CONF"
        
        deploy_sync_daemon
        echo -e "\n  ${G}● Auto-Sync Daemon Activated!${NC}"
        echo -e "  ${DIM}└─ Daemon will scan MPorter every 60s and automatically wrap ports destined for ${target_ip}.${NC}"
    fi

    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
    sleep 3
}

list_obfs() {
    echo -e "\n  ${B}╭────────────────── Active OBFS & Sync Rules ────────────────╮${NC}"
    local has_rules=false
    
    if [ -f "$SYNC_CONF" ]; then
        local idx=0
        while IFS='|' read -r sync_ip remote_pub stealth_port method; do
            [ -z "$sync_ip" ] && continue
            has_rules=true
            printf "  ${B}│${NC}  ${Y}C%-2s${NC} ${C}❯${NC} ${M}CLIENT SYNC${NC} ${DIM}Target:${NC} ${W}%-15s${NC} ${DIM}->${NC} ${C}%s:%s${NC} ${B}│${NC}\n" "$idx" "$sync_ip" "$remote_pub" "$stealth_port"
            ((idx++))
        done < "$SYNC_CONF"
    fi
    
    if [ -f "$OBFS_DIR/server_main.conf" ]; then
        has_rules=true
        local s_port=$(grep -oP '://:\K[0-9]+' "$OBFS_DIR/server_main.conf" | head -n 1)
        printf "  ${B}│${NC}  ${Y}S1 ${NC} ${C}❯${NC} ${C}SERVER RCVR${NC} ${DIM}Listening on Stealth Port:${NC} ${W}%-12s${NC} ${B}│${NC}\n" "$s_port"
    fi
    
    if [ "$has_rules" = false ]; then echo -e "  ${B}│${NC}  ${DIM}No OBFS transports configured.                              ${B}│${NC}"; fi
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC}  ${R}%-3s${NC} ${C}❯${NC} ${R}%-53s${NC} ${B}│${NC}\n" "rm" "Purge ALL OBFS rules & daemons"
    printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Go Back"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select 'rm' or 'q': ${NC}"; read l_opt

    if [[ "$l_opt" == "rm" ]]; then
        systemctl stop mshield-obfs mshield-sync 2>/dev/null
        systemctl disable mshield-obfs mshield-sync 2>/dev/null
        iptables -t nat -S OUTPUT 2>/dev/null | grep "MSHIELD_SYNC" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
        rm -rf "$OBFS_DIR" "$SYNC_CONF"
        if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
        echo -e "  ${G}● All OBFS layers and daemons completely wiped.${NC}"; sleep 1.5
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ FIREWALL & STEALTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Zero-Trust Firewall${NC}  ${DIM}(Auto-Whitelists MPorter & Tunnels)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Firewall${NC}              ${DIM}(Revert to open WAN)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Deploy Smart OBFS Layer${NC}       ${DIM}(MPorter Auto-Sync Engine)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Manage Active OBFS Transports${NC} ${DIM}(View/Delete)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MShield ❯❯ ${NC}"; read opt
    case $opt in
        1) activate_firewall ;;
        2) disable_firewall ;;
        3) smart_obfs_deploy ;;
        4) list_obfs ;;
        0) exit 0 ;;
    esac
done
EOF_MSHIELD
chmod +x /usr/bin/mshield
mshield
