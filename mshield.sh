#!/bin/bash
# --- MDesign Modular Core (mshield.sh) | Zero-Trust Firewall & MPorter-Sync OBFS v2.1.1 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'

OBFS_DIR="/etc/mshield/obfs"
SVC_FILE="/etc/systemd/system/mshield-obfs.service"
mkdir -p "$OBFS_DIR"

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

    clear; echo ""
    local str1=" MShield Zero-Trust & MPorter-Sync 2.1.1 "
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
    iptables -F MSHIELD >/dev/null 2>&1
    iptables -X MSHIELD >/dev/null 2>&1
    iptables -N MSHIELD

    # 1. Allow Local & Established
    iptables -A MSHIELD -i lo -j ACCEPT
    iptables -A MSHIELD -m state --state RELATED,ESTABLISHED -j ACCEPT

    # 2. Allow SSH
    local ssh_port=$(ss -tlnp 2>/dev/null | grep -i sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -n 1)
    [ -z "$ssh_port" ] && ssh_port=22
    iptables -A MSHIELD -p tcp --dport "$ssh_port" -j ACCEPT
    echo -e "  ${G}✔${NC} Secured SSH Management Port (${ssh_port})"

    # 3. Whitelist Peer IPs (Tunnels)
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

    # 4. Protect MPorter & OBFS Ports
    local fw_ports=""
    [ -f "/etc/haproxy/haproxy.cfg" ] && fw_ports+=$(awk '/frontend ft_/ {print $2}' /etc/haproxy/haproxy.cfg | sed 's/ft_//')"\n"
    [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1 && fw_ports+=$(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g')"\n"
    
    # Add OBFS Server ports to protection (Fixed Syntax Error)
    for conf in "$OBFS_DIR"/server_*.conf; do
        if [ -f "$conf" ]; then
            local obfs_p=$(grep -oP '://:\K[0-9]+' "$conf" | head -n 1)
            [ -n "$obfs_p" ] && fw_ports+="${obfs_p}\n"
        fi
    done
    # Add OBFS Client ports to protection (Fixed Syntax Error)
    for conf in "$OBFS_DIR"/client_*.conf; do
        if [ -f "$conf" ]; then
            local obfs_p=$(grep -oP 'tcp://:\K[0-9]+' "$conf" | head -n 1)
            [ -n "$obfs_p" ] && fw_ports+="${obfs_p}\n"
        fi
    done

    if [ -n "$fw_ports" ]; then
        local unique_ports=$(echo -e "$fw_ports" | sort -n -u | grep -v '^$')
        for port in $unique_ports; do
            iptables -A MSHIELD -p tcp --dport "$port" --syn -m limit --limit 25/s --limit-burst 100 -j ACCEPT
            iptables -A MSHIELD -p tcp --dport "$port" --syn -j DROP
            iptables -A MSHIELD -p tcp --dport "$port" -j ACCEPT
        done
        echo -e "  ${G}✔${NC} Secured $(echo "$unique_ports" | wc -w) MPorter/OBFS active ports with SYN-Flood protection."
    fi

    # 5. Stealth Drops (Scanners, Pings, Fabric)
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
# 2. SMART OBFS ENGINE (MPORTER SYNC)
# ==========================================
install_gost_if_needed() {
    if ! command -v gost >/dev/null 2>&1; then
        echo -e "  ${Y}● Gost Engine not found. Installing OBFS core...${NC}"
        wget -qO gost.gz https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz >/dev/null 2>&1
        gzip -d gost.gz; chmod +x gost; mv gost /usr/local/bin/gost
    fi
}

apply_obfs_service() {
    local commands=""
    for conf in "$OBFS_DIR"/*.conf; do
        [ -f "$conf" ] && commands+="$(cat "$conf")\n"
    done
    
    if [ -z "$commands" ]; then
        systemctl stop mshield-obfs.service >/dev/null 2>&1
        systemctl disable mshield-obfs.service >/dev/null 2>&1
        return
    fi
    
    cat <<EOF > /usr/local/bin/mshield-runner.sh
#!/bin/bash
while true; do
$(echo -e "$commands" | grep -v '^$' | awk '{print $0 " &"}')
wait
done
EOF
    chmod +x /usr/local/bin/mshield-runner.sh

    cat <<EOF > "$SVC_FILE"
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
}

smart_obfs_deploy() {
    install_gost_if_needed
    echo -e "\n  ${DIM}┌─[ SMART OBFS DEPLOYMENT ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}SERVER Mode (Exit Node / Kharej)${NC} ${DIM}- Decrypts and feeds to MPorter${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}CLIENT Mode (Entry Node / Iran)${NC}  ${DIM}- Encrypts and sends to Kharej${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read o_mode
    
    [[ "$o_mode" != "1" && "$o_mode" != "2" ]] && return

    echo -ne "\n  ${C}●${NC} ${W}Select Transport Protocol [1: TLS | 2: Websocket (WS) | 3: WSS]: ${NC}"; read t_proto
    local method="relay+tls"
    [ "$t_proto" == "2" ] && method="relay+ws"
    [ "$t_proto" == "3" ] && method="relay+wss"

    local c_id=$(date +%s%N | cut -b1-13)

    if [ "$o_mode" == "1" ]; then
        # MPorter Auto-Discovery
        declare -a mp_rules
        declare -a mp_ports
        
        if [ -f "/etc/haproxy/haproxy.cfg" ]; then
            while read -r p t; do
                p=${p#srv_}
                mp_rules+=("HAProxy | Port: $p ➔ $t")
                mp_ports+=("$p")
            done < <(awk '/server srv_/ {print $2 " " $3}' /etc/haproxy/haproxy.cfg 2>/dev/null)
        fi
        
        if [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1; then
            while read -r raw; do
                p=$(echo "$raw" | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/')
                t=$(echo "$raw" | sed -E 's/.*\/([0-9\.]+:[0-9]+).*/\1/')
                mp_rules+=("Gost    | Port: $p ➔ $t")
                mp_ports+=("$p")
            done < <(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null)
        fi

        local target_port=""
        if [ ${#mp_rules[@]} -gt 0 ]; then
            echo -e "\n  ${B}╭─── Discovered MPorter Forwarding Rules ───╮${NC}"
            for i in "${!mp_rules[@]}"; do
                printf "  ${B}│${NC}  ${Y}%-2s${NC} ${C}❯${NC} ${W}%-35s${NC} ${B}│${NC}\n" "$i" "${mp_rules[$i]}"
            done
            echo -e "  ${B}├───────────────────────────────────────────┤${NC}"
            printf "  ${B}│${NC}  ${Y}%-2s${NC} ${C}❯${NC} ${M}%-35s${NC} ${B}│${NC}\n" "m" "Manual Port Entry"
            echo -e "  ${B}╰───────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}●${NC} ${W}Select Rule to Hide (0-$(( ${#mp_rules[@]} - 1 )) or 'm'): ${NC}"; read r_sel
            
            if [[ "$r_sel" == "m" ]]; then
                echo -ne "  ${C}●${NC} ${W}Enter Local Port manually: ${NC}"; read target_port
            elif [[ -n "${mp_ports[$r_sel]}" ]]; then
                target_port="${mp_ports[$r_sel]}"
                echo -e "  ${G}✔ Selected Port to Hide: ${target_port}${NC}"
            else
                echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return
            fi
        else
            echo -e "\n  ${Y}● No MPorter rules found. Manual entry required.${NC}"
            echo -ne "  ${C}●${NC} ${W}Enter Local Port to feed decrypted traffic to: ${NC}"; read target_port
        fi

        [ -z "$target_port" ] && return
        echo -ne "  ${C}●${NC} ${W}Enter Stealth Port to expose to Internet (e.g. 443, 8443): ${NC}"; read s_port
        [ -z "$s_port" ] && return
        
        local cmd="/usr/local/bin/gost -L $method://:$s_port/127.0.0.1:$target_port"
        echo "$cmd" > "$OBFS_DIR/server_${c_id}.conf"
        echo -e "\n  ${G}● Server OBFS wrapper created!${NC}"
        echo -e "  ${DIM}└─ [Internet] -> (:$s_port Stealth) -> (:$target_port MPorter) -> [Destination]${NC}"
    
    elif [ "$o_mode" == "2" ]; then
        echo -ne "  ${C}●${NC} ${W}Traffic Type [1: TCP | 2: UDP]: ${NC}"; read l_proto
        local f_proto="tcp"; [ "$l_proto" == "2" ] && f_proto="udp"
        
        echo -ne "  ${C}●${NC} ${W}Open Local Raw Port for Users (e.g. 80, 4789): ${NC}"; read l_port
        echo -ne "  ${C}●${NC} ${W}Remote Server IP (Kharej): ${NC}"; read r_ip
        echo -ne "  ${C}●${NC} ${W}Remote Stealth Port (Kharej OBFS Port): ${NC}"; read r_port
        [ -z "$l_port" ] || [ -z "$r_ip" ] || [ -z "$r_port" ] && return
        
        local cmd="/usr/local/bin/gost -L $f_proto://:$l_port -F $method://$r_ip:$r_port"
        echo "$cmd" > "$OBFS_DIR/client_${c_id}.conf"
        echo -e "\n  ${G}● Client OBFS wrapper created!${NC}"
        echo -e "  ${DIM}└─ [Users] -> (:$l_port Raw) -> (Encrypted) -> [$r_ip:$r_port]${NC}"
    fi

    apply_obfs_service
    
    # Reload Firewall to protect new ports
    if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then
        echo -e "  ${DIM}● Synchronizing Zero-Trust Firewall with new OBFS ports...${NC}"
        activate_firewall >/dev/null
    fi
    sleep 2.5
}

list_obfs() {
    local configs=($(ls "$OBFS_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No OBFS transports configured!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${B}╭────────────────── Active OBFS Transports ──────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        local c_type="${G}CLIENT${NC} (Iran)"
        [[ "${configs[$i]}" == *"server"* ]] && c_type="${C}SERVER${NC} (Kharej)"
        local c_cmd=$(cat "${configs[$i]}" | sed 's/\/usr\/local\/bin\/gost //')
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} %b%-24s%b ${DIM}CMD:${NC} ${W}%-31s${NC} ${B}│${NC}\n" "$i" "" "$c_type" "" "${c_cmd:0:30}..."
    done
    echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC}  ${R}%-3s${NC} ${C}❯${NC} ${R}%-53s${NC} ${B}│${NC}\n" "rm" "Delete a transport"
    printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Go Back"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select 'rm' or 'q': ${NC}"; read l_opt

    if [[ "$l_opt" == "rm" ]]; then
        echo -ne "  ${C}●${NC} ${W}Enter Index to delete: ${NC}"; read rm_idx
        if [[ -n "${configs[$rm_idx]}" ]]; then
            rm -f "${configs[$rm_idx]}"
            apply_obfs_service
            if iptables -C INPUT -j MSHIELD >/dev/null 2>&1; then activate_firewall >/dev/null; fi
            echo -e "  ${G}● Transport removed & Firewall synced.${NC}"; sleep 1.5
        fi
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ FIREWALL & STEALTH ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Activate Zero-Trust Firewall${NC}  ${DIM}(Auto-Whitelists MPorter & Tunnels)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Disable Firewall${NC}              ${DIM}(Revert to open WAN)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Deploy Smart OBFS Layer${NC}       ${DIM}(MPorter Auto-Sync)${NC}"
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
