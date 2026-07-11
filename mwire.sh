cat << 'EOF_MWIRE' > /usr/bin/mwire
#!/bin/bash
# --- MWIRE Crypto Secure Matrix (mwire.sh) | MDesign Core v1.2.0 (Offline Cache Patch) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
PEER_DIR="${WG_DIR}/peers"
LOCAL_DIR="/root/mtunnel"

mkdir -p "$WG_DIR" "$PEER_DIR"
chmod 700 "$WG_DIR" "$PEER_DIR"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

check_dependencies() {
    if ! command -v wg >/dev/null 2>&1 || ! command -v qrencode >/dev/null 2>&1; then
        echo -e "\n  ${Y}● WireGuard & QR tools missing. Deploying components...${NC}"
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        if ls "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1; then
            echo -e "  ${DIM}├─ Installing from Local Offline Cache...${NC}"
            dpkg -i "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1
            apt-get install -f -y -q >/dev/null 2>&1
        else
            echo -e "  ${DIM}├─ Downloading from Network & Caching Locally...${NC}"
            apt-get update -y -q >/dev/null 2>&1
            apt-get install -d -y -q wireguard wireguard-tools qrencode >/dev/null 2>&1
            cp /var/cache/apt/archives/*.deb "$LOCAL_DIR/packages/" 2>/dev/null
            apt-get install -y -q wireguard wireguard-tools qrencode >/dev/null 2>&1
        fi
        echo -e "  ${G}● Dependencies installed successfully!${NC}"
    fi
}

draw_mwire_header() {
    local s_ip=$(get_local_ip); local active_peers=0; local srv_status="OFFLINE"; local srv_color="${R}"
    if pgrep -x "wg-crypt-wg0" >/dev/null 2>&1 || ip link show wg0 >/dev/null 2>&1; then
        srv_status="ONLINE"; srv_color="${G}"
        active_peers=$(wg show wg0 peers 2>/dev/null | wc -l)
    fi
    clear; echo ""
    local str1=" MWIRE Crypto Matrix 1.2.0 "
    local str2=" IP: $s_ip "
    local str3=" SERVER: $srv_status "
    local str4=" PEERS: $active_peers "
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} + 1 + ${#str4} ))
    local pad_len=$(( 92 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} SERVER:${NC}${srv_color} ${srv_status} ${NC}${B}│${NC}${DIM} PEERS:${NC}${Y} ${active_peers} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

init_wg_server() {
    if [ -f "$WG_CONF" ]; then
        echo -e "\n  ${Y}● WireGuard Server is already initialized!${NC}"
        sleep 1.5; return
    fi

    echo -e "\n  ${DIM}┌─[ INITIALIZE CRYPTO SERVER Core ]${NC}"
    
    local wg_port="51820"
    while true; do
        echo -ne "  ${C}●${NC} ${W}WireGuard Listen Port [${Y}51820${W}] (Or 'q' to Cancel): ${NC}"; read input_port
        [[ "$input_port" == "q" ]] && return
        [ -n "$input_port" ] && wg_port=$input_port
        break
    done

    local wg_subnet="10.8.0.1"
    while true; do
        echo -ne "  ${C}●${NC} ${W}Server Inside IP / Subnet [${Y}10.8.0.1${W}]: ${NC}"; read input_sub
        [[ "$input_sub" == "q" ]] && return
        [ -n "$input_sub" ] && wg_subnet=$input_sub
        break
    done

    local server_priv=$(wg genkey)
    local server_pub=$(echo "$server_priv" | wg pubkey)
    
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    local eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
    [ -z "$eth_iface" ] && eth_iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;exit}' | tr -d ' ')

    cat <<EOF > "$WG_CONF"
[Interface]
PrivateKey = $server_priv
Address = ${wg_subnet}/24
ListenPort = $wg_port
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $eth_iface -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $eth_iface -j MASQUERADE
EOF

    chmod 600 "$WG_CONF"
    systemctl enable wg-quick@wg0 >/dev/null 2>&1
    systemctl start wg-quick@wg0 >/dev/null 2>&1

    echo -e "\n  ${G}● WireGuard Server deployed successfully!${NC}"
    echo -e "  ${DIM}├─ Public Key: ${W}${server_pub}${NC}"
    echo -e "  ${DIM}└─ Listen Port: ${Y}${wg_port}${NC}"
    sleep 3
}

generate_peer() {
    if [ ! -f "$WG_CONF" ]; then
        echo -e "\n  ${R}● Initialize WireGuard server core first (Option 1)!${NC}"
        sleep 2; return
    fi

    echo -e "\n  ${DIM}┌─[ GENERATE CRYPTO PEER MATRIX ]${NC}"
    
    local p_name=""
    while true; do
        echo -ne "  ${C}●${NC} ${W}Enter Peer Name (No spaces | q:Back): ${NC}"; read p_name
        [[ "$p_name" == "q" ]] && return
        [[ -z "$p_name" ]] && continue
        [ -f "$PEER_DIR/${p_name}.conf" ] && echo -e "  ${R}● Peer name already exists!${NC}" && continue
        break
    done

    local server_ip=$(grep "Address" "$WG_CONF" | awk '{print $3}' | cut -d'/' -f1)
    local base_ip=$(echo "$server_ip" | cut -d'.' -f1-3)
    local last_octet=$(echo "$server_ip" | cut -d'.' -f4)
    
    local next_octet=$((last_octet + 1))
    while grep -q "${base_ip}.${next_octet}" "$WG_CONF" || grep -q "${base_ip}.${next_octet}" "$PEER_DIR"/*.conf 2>/dev/null; do
        next_octet=$((next_octet + 1))
    done
    local peer_ip="${base_ip}.${next_octet}"

    local peer_priv=$(wg genkey)
    local peer_pub=$(echo "$peer_priv" | wg pubkey)
    local peer_psk=$(wg genpsk)
    local srv_pub=$(wg show wg0 public-key 2>/dev/null)
    local srv_port=$(grep "ListenPort" "$WG_CONF" | awk '{print $3}')
    local srv_pub_ip=$(get_local_ip)

    cat <<EOF >> "$WG_CONF"

# --- Peer: ${p_name} ---
[Peer]
PublicKey = $peer_pub
PresharedKey = $peer_psk
AllowedIPs = ${peer_ip}/32
EOF

    wg syncconf wg0 <(wg-quick strip wg0)

    cat <<EOF > "$PEER_DIR/${p_name}.conf"
[Interface]
PrivateKey = $peer_priv
Address = ${peer_ip}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $srv_pub
PresharedKey = $peer_psk
Endpoint = ${srv_pub_ip}:${srv_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "$PEER_DIR/${p_name}.conf"
    
    echo -e "\n  ${G}● Peer Matrix generated successfully!${NC}"
    echo -e "  ${DIM}├─ Peer File: ${W}${PEER_DIR}/${p_name}.conf${NC}"
    echo -e "  ${DIM}└─ Allocated IP: ${Y}${peer_ip}${NC}\n"
    
    echo -e "  ${C}▼ CLIENT CONFIGURATION TEXT:${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    cat "$PEER_DIR/${p_name}.conf"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "\n  ${M}▼ MOBILE SCAN SCANNER (QR CODE):${NC}"
        qrencode -t ansiutf8 < "$PEER_DIR/${p_name}.conf"
    fi
    
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
}

show_active_peers() {
    if [ ! -f "$WG_CONF" ] || ! ip link show wg0 >/dev/null 2>&1; then
        echo -e "\n  ${R}● WireGuard interface wg0 is inactive or not deployed!${NC}"
        sleep 2; return
    fi
    echo -e "\n  ${C}Live Encryption Engine Tunnel Matrix:${NC}"
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    
    while read -r line; do
        printf "  ${B}│${NC}  %-88s  ${B}│${NC}\n" "$line"
    done < <(wg show wg0)
    
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read
}

remove_peer_or_server() {
    if [ ! -f "$WG_CONF" ]; then
        echo -e "\n  ${R}● No active WireGuard deployment detected!${NC}"
        sleep 1.5; return
    fi

    echo -e "\n  ${DIM}┌─[ DESTROY MATRIX COMPONENTS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${Y}Remove Specific Client Peer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Completely Wipe WireGuard Core Server${NC}"
    echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
    
    local choice=""
    while true; do
        echo -ne "  ${C}●${NC} ${W}Select Destruction Target: ${NC}"; read choice
        [[ "$choice" == "q" ]] && return
        [[ "$choice" == "1" || "$choice" == "2" ]] && break
    done

    if [[ "$choice" == "1" ]]; then
        local peer_files=($(ls "$PEER_DIR"/*.conf 2>/dev/null))
        if [ ${#peer_files[@]} -eq 0 ]; then echo -e "\n  ${R}● No clients found to remove!${NC}"; sleep 1.5; return; fi
        
        echo -e "\n  ${B}╭────────────────── Select Peer to Terminate ────────────────╮${NC}"
        for i in "${!peer_files[@]}"; do
            local p_name=$(basename "${peer_files[$i]}" .conf)
            printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$p_name"
        done
        echo -e "  ${B}├────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${DIM}%-53s${NC} ${B}│${NC}\n" "q" "Cancel and Return"
        echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
        
        local p_idx=""
        while true; do
            echo -ne "  ${C}●${NC} ${W}Select Index: ${NC}"; read p_idx
            [[ "$p_idx" == "q" ]] && return
            [[ -n "$p_idx" && -n "${peer_files[$p_idx]}" ]] && break
        done

        local target_name=$(basename "${peer_files[$p_idx]}" .conf)
        
        sed -i "/# --- Peer: ${target_name} ---/,+4d" "$WG_CONF"
        rm -f "${peer_files[$p_idx]}"
        
        wg syncconf wg0 <(wg-quick strip wg0)
        echo -e "  ${G}● Peer [${target_name}] has been terminated and purged.${NC}"; sleep 1.5

    elif [[ "$choice" == "2" ]]; then
        echo -ne "  ${R}● DANGER: Completely wipe WireGuard server and all clients? (y/n): ${NC}"; read confirm
        if [[ "$confirm" == "y" ]]; then
            systemctl stop wg-quick@wg0 >/dev/null 2>&1
            systemctl disable wg-quick@wg0 >/dev/null 2>&1
            rm -rf "$WG_DIR"
            echo -e "  ${G}● WireGuard Core ecosystem successfully annihilated.${NC}"; sleep 1.5
        fi
    fi
}

import_client_config() {
    if [ -f "$WG_CONF" ]; then
        echo -e "\n  ${R}● WireGuard configuration already exists on this server!${NC}"
        echo -e "  ${DIM}├─ If you want to import a new one, delete the old one first (Option 4).${NC}"
        sleep 2.5; return
    fi

    echo -e "\n  ${DIM}┌─[ IMPORT CLIENT CONFIGURATION ]${NC}"
    echo -e "  ${DIM}│${NC} ${Y}Paste the entire configuration text generated by your Server here.${NC}"
    echo -e "  ${DIM}│${NC} ${Y}When you are finished pasting, type ${W}SAVE${Y} on a new line and press Enter.${NC}"
    echo -e "  ${DIM}└────────────────────────────────────────────────────────────────────────${NC}\n"

    local temp_conf="/tmp/wg0_import.conf"
    > "$temp_conf"

    while IFS= read -r line; do
        if [[ "$line" == "SAVE" || "$line" == "save" ]]; then
            break
        fi
        echo "$line" >> "$temp_conf"
    done

    if [ ! -s "$temp_conf" ]; then
        echo -e "\n  ${R}● Error: Empty configuration received! Import aborted.${NC}"
        rm -f "$temp_conf"; sleep 2; return
    fi

    mv "$temp_conf" "$WG_CONF"
    chmod 600 "$WG_CONF"
    
    systemctl enable wg-quick@wg0 >/dev/null 2>&1
    systemctl start wg-quick@wg0 >/dev/null 2>&1

    if ip link show wg0 >/dev/null 2>&1; then
        echo -e "\n  ${G}● Client Node deployed successfully! Connected to Matrix.${NC}"
        echo -e "  ${DIM}├─ Interface: ${W}wg0${NC}"
        echo -e "  ${DIM}└─ Status: ${G}ONLINE${NC}"
    else
        echo -e "\n  ${R}● Failed to start WireGuard interface. Check configuration syntax.${NC}"
    fi
    sleep 3
}

check_dependencies

while true; do
    draw_mwire_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Initialize WireGuard Server Core${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Generate Secure Peer Configuration (Client Key)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${W}Show Active Peer Connections (wg show)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Remove Crypto Peer / Turn Off Server${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}Deploy Node as Client (Import Config)${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Tunnel Hub${NC}\n"
    echo -ne "  ${G}MWIRE ❯❯ ${NC}"; read opt
    case $opt in
        1) init_wg_server ;;
        2) generate_peer ;;
        3) show_active_peers ;;
        4) remove_peer_or_server ;;
        5) import_client_config ;;
        0) break ;;
    esac
done
EOF_MWIRE
chmod +x /usr/bin/mwire
