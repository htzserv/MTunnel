#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Tri-Core Matrix v7.9.0 ---
# [Dual-Stack IPv4/IPv6 Support | Engines: 1. HAProxy | 2. Gost | 3. iptables/ip6tables]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mporter"
H_CONF="/etc/haproxy/haproxy.cfg"
G_CONF="/etc/gost/config.json"
IPT_CONF="/etc/mporter/iptables_nat.sh"
LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

mkdir -p "$LOCAL_DIR/packages" /etc/haproxy /var/lib/haproxy /etc/gost /etc/mporter /usr/sbin /usr/local/sbin /usr/local/bin 2>/dev/null
touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null

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

enable_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
}

is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}

format_target() {
    local ip="$1"; local port="$2"
    if is_ipv6 "$ip"; then echo "[${ip}]:${port}"; else echo "${ip}:${port}"; fi
}

ensure_gost() {
    if [ ! -f /usr/local/bin/gost ]; then
        local P_DIR=$(get_pkg_dir)
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        if [ -s "$P_DIR/gost" ]; then
            cp -f "$P_DIR/gost" /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
        else
            wget --timeout=5 --tries=1 -qO "/tmp/gost.gz" https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz >/dev/null 2>&1
            if [ -s "/tmp/gost.gz" ]; then
                gzip -d "/tmp/gost.gz"
                mv "/tmp/gost" /usr/local/bin/gost
                chmod +x /usr/local/bin/gost
            fi
        fi
    fi
}

apply_iptables_rules() {
    iptables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do iptables -t nat $rule 2>/dev/null; done
    iptables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do iptables -t nat $rule 2>/dev/null; done
    ip6tables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do ip6tables -t nat $rule 2>/dev/null; done
    ip6tables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do ip6tables -t nat $rule 2>/dev/null; done
    if [ -s "$IPT_CONF" ]; then
        bash "$IPT_CONF" 2>/dev/null
    fi
}

purge_ip_core() {
    local target_ip="$1"
    local t_ports=""
    
    [ -f "$H_CONF" ] && t_ports+=$(grep -E "${target_ip}(:|\])" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip" | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g' | xargs)
    [ -f "$IPT_CONF" ] && t_ports+=" "$(grep "$target_ip" "$IPT_CONF" 2>/dev/null | grep -oP '--dport \K[0-9]+' | xargs)
    t_ports=$(echo "$t_ports" | tr ' ' '\n' | grep -v '^$' | sort -un | xargs)
    
    for p in $t_ports; do
        sed -i "/frontend ft_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/bind :::${p} /d" "$H_CONF" 2>/dev/null
        sed -i "/bind \*:$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/default_backend bk_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/backend bk_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/server srv_$p /d" "$H_CONF" 2>/dev/null
        sed -i "/server srv_${p}_[0-9]\+ /d" "$H_CONF" 2>/dev/null
        
        if command -v jq >/dev/null 2>&1 && [ -f "$G_CONF" ]; then 
            jq --arg p "$p" '.ServeNodes = [.ServeNodes[]? | select(startswith("tcp://:"+$p+"/") or startswith("tcp://[::]:"+$p+"/") | not)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF" 2>/dev/null
        fi
        
        sed -i "/--dport $p /d" "$IPT_CONF" 2>/dev/null
    done
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
    sed -i "/$target_ip/d" "$IPT_CONF" 2>/dev/null
    apply_iptables_rules
    echo "$(date) | Purged Target IP: $target_ip and its associated ports." >> /var/log/mporter-watchdog.log
}

# --- 🌟 BACKEND APIs 🌟 ---
if [[ "$1" == "--purge-ip" && -n "$2" ]]; then
    purge_ip_core "$2"
    systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
    exit 0
fi

if [[ "$1" == "--cleanup-orphans" ]]; then
    h_ips=$(grep -oP 'server srv_[0-9]+ \K\[?[0-9a-fA-F\.:]+\]?' "$H_CONF" 2>/dev/null | tr -d '[]' | sort -u)
    g_ips=""
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K\[?[0-9a-fA-F\.:]+\]?' | tr -d '[]' | cut -d: -f1 | sort -u)
    ipt_ips=$(grep -oP -- '--to-destination \K\[?[0-9a-fA-F\.:]+\]?' "$IPT_CONF" 2>/dev/null | tr -d '[]' | sort -u)
    all_ips=$(echo -e "$h_ips\n$g_ips\n$ipt_ips" | sort -u)
    
    for ip in $all_ips; do
        if is_ipv6 "$ip"; then
            found=false
            grep -qR "$ip" /etc/mgre/ 2>/dev/null && found=true
            [ "$found" = false ] && purge_ip_core "$ip"
        else
            subnet=$(echo "$ip" | cut -d'.' -f1-3)
            found=false
            grep -qR "CORE_SUBNET=$subnet" /etc/mgre/ 2>/dev/null && found=true
            [ "$found" = false ] && purge_ip_core "$ip"
        fi
    done
    systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
    exit 0
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

install_haproxy_core() {
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
    bind :::9999 v4v6
    default_backend dummy_back
backend dummy_back
    server local 127.0.0.1:9999
EOF_HAP
    fi

    local HAP_BIN="/usr/sbin/haproxy"
    [ ! -f "$HAP_BIN" ] && [ -f "/usr/local/sbin/haproxy" ] && HAP_BIN="/usr/local/sbin/haproxy"

    if [ ! -f /etc/systemd/system/haproxy.service ]; then
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
}

install_gost_core() {
    ensure_gost
    mkdir -p /etc/gost 2>/dev/null
    if [ ! -f "$G_CONF" ] || ! jq . "$G_CONF" >/dev/null 2>&1; then 
        echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
    fi
    cat <<'EOF_GST' > /etc/systemd/system/gost.service
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
EOF_GST
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable gost >/dev/null 2>&1
    systemctl restart gost >/dev/null 2>&1 || true
}

fix_and_install() {
    echo -e "\n  ${DIM}┌─[ SELECT CORE ENGINE TO INSTALL ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy Dual-Stack Engine${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost Multi-Protocol Engine${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}iptables/ip6tables Kernel NAT Core${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Install All Engines (Tri-Core Full Deployment)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Install ❯❯ ${NC}"; read core_opt
    core_opt=$(echo "$core_opt" | tr -d '\r' | tr -d ' ')

    if [[ "$core_opt" =~ ^[1-4]$ ]]; then
        (
            enable_forwarding
            case $core_opt in
                1) install_haproxy_core ;;
                2) install_gost_core ;;
                3) enable_forwarding ;;
                4) install_haproxy_core; install_gost_core; enable_forwarding ;;
            esac
        ) &
        local p_pid=$!
        draw_progress_bar "$p_pid" "Deploying Engines"
        wait "$p_pid"
        echo -e "\n  ${G}● Engine Installation & Configuration Complete.${NC}"
        sleep 1.5
    fi
}

get_iface_for_ip() {
    local target_ip=$1
    if is_ipv6 "$target_ip"; then
        local iface=$(ip -o -6 addr show 2>/dev/null | grep -w "${target_ip%/*}" | awk '{print $2}' | head -n 1)
        [ -z "$iface" ] && iface=$(ip -6 route get "$target_ip" 2>/dev/null | grep -oP 'dev \K\S+' | head -n 1)
        echo "${iface:-IPv6_Tunnel}"
    else
        local subnet=$(echo "$target_ip" | cut -d'.' -f1-3)
        local iface=$(ip -o -4 addr show 2>/dev/null | grep -w "${subnet}\." | awk '{print $2}' | head -n 1)
        echo "${iface:-Unknown}"
    fi
}

get_stats() {
    server_ip=$(get_local_ip)
    if systemctl is-active --quiet haproxy; then hap_stat="${G}●${NC}"; raw_hap="●"; else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi
    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"; else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    if [ -s "$IPT_CONF" ]; then ipt_stat="${Y}●${NC}"; raw_ipt="●"; else ipt_stat="${DIM}○${NC}"; raw_ipt="○"; fi
    
    local h_ports=0; local g_ports=0; local ipt_ports=0
    if [ -f "$H_CONF" ]; then h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--)); [ "$h_ports" -lt 0 ] && h_ports=0; fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_ports=$(jq '.ServeNodes | length' "$G_CONF" 2>/dev/null); [ -z "$g_ports" ] && g_ports=0; fi
    if [ -f "$IPT_CONF" ]; then ipt_ports=$(grep -c -E '--dport [0-9]+' "$IPT_CONF" 2>/dev/null); fi
    total_ports=$((h_ports + g_ports + ipt_ports))

    local h_ips=""; local g_ips=""; local ipt_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep -oP 'server srv_[0-9_]+ \K\[?[0-9a-fA-F\.:]+\]?' "$H_CONF" 2>/dev/null | tr -d '[]')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K\[?[0-9a-fA-F\.:]+\]?' | tr -d '[]' | cut -d: -f1)
    [ -f "$IPT_CONF" ] && ipt_ips=$(grep -oP -- '--to-destination \K\[?[0-9a-fA-F\.:]+\]?' "$IPT_CONF" 2>/dev/null | tr -d '[]')
    
    local all_ips=$(echo -e "$h_ips\n$g_ips\n$ipt_ips" | grep -v '^$' | sort -u)
    mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"
    else ip_status="${DIM}NONE${NC}"; raw_ip="NONE"; fi
}

draw_header() {
    get_stats; clear; echo ""
    raw_text=" MPorter 7.9.0 │ IP: $server_ip │ HAP: $raw_hap │ Gost: $raw_gst │ IPT: $raw_ipt │ IPs: $raw_ip │ Pts: $total_ports "
    pad_len=$(( 92 - ${#raw_text} ))
    if (( pad_len < 0 )); then pad_len=0; fi
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter 7.9.0 (Dual-Stack)${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${server_ip}${NC} ${B}│${NC} ${DIM}HAP:${NC} ${hap_stat} ${B}│${NC} ${DIM}Gost:${NC} ${gst_stat} ${B}│${NC} ${DIM}IPT:${NC} ${ipt_stat} ${B}│${NC} ${DIM}Pts:${NC} ${G}${total_ports}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}├──────────────┬────────────────────────────────────────────┬────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-30s${NC} ${B}│${NC}\n" "INTERFACE" "TARGET NETWORK IPs (v4/v6)" "TOTAL FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼────────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E 'server srv_[0-9_]+ \[?[0-9a-fA-F\.:]+\]?' "$H_CONF" 2>/dev/null | awk '{print $3}' | tr -d '[]' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K\[?[0-9a-fA-F\.:]+\]?' | tr -d '[]' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- '--to-destination \K\[?[0-9a-fA-F\.:]+\]?' "$IPT_CONF" 2>/dev/null | tr -d '[]' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    
    local ip_port_counts=$(echo -e "$h_map\n$g_map\n$ipt_map" | grep -v '^$' | awk -F'|' '{a[$1]+=$2} END {for (i in a) print i"|"a[i]}')

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
    echo -e "\n  ${DIM}┌─[ SELECT FORWARDING ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy Dual-Stack${NC} ${DIM}(Handles both IPv4 & IPv6 seamlessly)${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost Relay${NC} ${DIM}(Multi-protocol IPv4/IPv6)${NC}"
    echo -e "  ${DIM}│${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}iptables/ip6tables DNAT${NC} ${DIM}(Kernel-space Line-rate NAT)${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read fwd_engine
    fwd_engine=$(echo "$fwd_engine" | tr -d '\r' | tr -d ' ')
    
    if [[ ! "$fwd_engine" =~ ^[1-3]$ ]]; then echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; fi
    if [ "$fwd_engine" == "2" ] && ! command -v jq >/dev/null 2>&1; then echo -e "  ${R}● Gost requires 'jq'. Run Installer (1) first.${NC}"; sleep 2; return; fi

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
        echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP (IPv4 or IPv6) manually: ${NC}"; read target_ip
        target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
        selected_if="Manual"
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (IPv4 or IPv6)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface (0-$(( ${#gre_ifs[@]} - 1 )) or 'm'): ${NC}"; read if_choice
        if_choice=$(echo "$if_choice" | tr -d '\r' | tr -d ' ')
        
        if [[ "$if_choice" == "m" ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP (IPv4 or IPv6): ${NC}"; read target_ip
            target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
            selected_if="Manual"
        elif [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
            local map_ip6s=($(ip -o -6 addr show "$selected_if" 2>/dev/null | grep -v 'fe80:' | awk '{print $4}' | cut -d/ -f1))
            map_ips+=("${map_ip6s[@]}")

            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -e "  ${R}● No active IPs found on ${selected_if}!${NC}"
                echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
                target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                echo -e "  ${DIM}Tip: Enter 'a' to auto-distribute ports across ALL IPs.${NC}"
                echo -ne "  ${C}●${NC} ${W}Select EXACT Index (0-$(( ${#map_ips[@]} - 1 ))) or 'a': ${NC}"; read ip_choice
                ip_choice=$(echo "$ip_choice" | tr -d '\r' | tr -d ' ')
                
                if [[ "$ip_choice" == "a" ]]; then
                    selected_ips=("${map_ips[@]}")
                    is_auto_all=true
                    echo -e "  ${G}✔ Auto-Distribute mode enabled for ${#selected_ips[@]} IPs.${NC}"
                elif [[ -n "${map_ips[$ip_choice]}" ]]; then 
                    local selected_local_ip="${map_ips[$ip_choice]}"
                    local calc_target=""
                    if is_ipv6 "$selected_local_ip"; then
                        calc_target="${selected_local_ip%:*}:$([ "${selected_local_ip##*:}" == "1" ] && echo "2" || echo "1")"
                    else
                        local base_ip=$(echo "$selected_local_ip" | cut -d'.' -f1-3); local last_octet=$(echo "$selected_local_ip" | cut -d'.' -f4)
                        calc_target="${base_ip}.$([ "$last_octet" == "1" ] && echo "2" || echo "1")"
                    fi
                    
                    echo -ne "\n  ${C}●${NC} ${W}Confirm Target Destination IP [${calc_target}]: ${NC}"; read custom_target
                    custom_target=$(echo "$custom_target" | tr -d '\r' | tr -d ' ')
                    target_ip="${custom_target:-$calc_target}"
                else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            fi
        else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
    fi

    [ "$is_auto_all" != true ] && [ -z "$target_ip" ] && { echo -e "  ${R}● Target IP cannot be empty!${NC}"; sleep 1; return; }

    echo -ne "\n  ${C}●${NC} ${W}Enter Exact Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports
    raw_ports=$(echo "$raw_ports" | tr -d '\r')
    if ! [[ "$raw_ports" =~ ^[0-9,]+$ ]]; then
        echo -e "  ${R}● Invalid port format! Use numbers and commas only.${NC}"; sleep 1.5; return
    fi
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    
    echo -e "\n  ${Y}● Applying Strict 1-to-1 Dual-Stack Mappings...${NC}"
    echo -e "  ${B}╭──────────────┬─────────────┬────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-11s${NC} ${B}│${NC} ${W}%-38s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Target IP"
    echo -e "  ${B}├──────────────┼─────────────┼────────────────────────────────────────┤${NC}"
    
    local port_idx=0
    for p in $clean_ports; do
        if [ "$is_auto_all" = true ]; then
            local cur_ip="${selected_ips[$((port_idx % ${#selected_ips[@]}))]}"
            if is_ipv6 "$cur_ip"; then
                target_ip="${cur_ip%:*}:$([ "${cur_ip##*:}" == "1" ] && echo "2" || echo "1")"
            else
                local base_ip=$(echo "$cur_ip" | cut -d'.' -f1-3); local last_octet=$(echo "$cur_ip" | cut -d'.' -f4)
                target_ip="${base_ip}.$([ "$last_octet" == "1" ] && echo "2" || echo "1")"
            fi
        fi

        local skip_reason=""
        if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then skip_reason="OS/System"
        elif grep -q -w "frontend ft_$p" "$H_CONF" 2>/dev/null; then skip_reason="HAProxy"
        elif [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && jq -e ".ServeNodes[] | select(. | contains(\":$p/\"))" "$G_CONF" >/dev/null 2>&1; then skip_reason="Gost"
        elif grep -q "dport $p " "$IPT_CONF" 2>/dev/null; then skip_reason="iptables"
        fi

        if [ -n "$skip_reason" ]; then
            printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-11s${NC} ${B}│${NC} ${DIM}%-38s${NC} ${B}│${NC}\n" "$p" "-" "Skipped (Used by $skip_reason)"
            continue
        fi
        
        if [ "$fwd_engine" == "1" ]; then
            local srv_target=$(format_target "$target_ip" "$p")
            (
                flock -x 200
                echo -e "\nfrontend ft_$p\n    bind :::${p} v4v6\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $srv_target check inter 5000" >> "$H_CONF"
            ) 200>/var/lock/mporter_haproxy.lock
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-11s${NC} ${B}│${NC} ${W}%-38s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$target_ip"
        
        elif [ "$fwd_engine" == "2" ]; then
            local node_str="tcp://[::]:$p/$(format_target "$target_ip" "$p")"
            jq --arg node "$node_str" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-11s${NC} ${B}│${NC} ${W}%-38s${NC} ${B}│${NC}\n" "$p" "Gost" "$target_ip"
            
        elif [ "$fwd_engine" == "3" ]; then
            enable_forwarding
            if is_ipv6 "$target_ip"; then
                echo "ip6tables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination [${target_ip}]:$p" >> "$IPT_CONF"
                echo "ip6tables -t nat -A PREROUTING -p udp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination [${target_ip}]:$p" >> "$IPT_CONF"
                echo "ip6tables -t nat -A POSTROUTING -p tcp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
                echo "ip6tables -t nat -A POSTROUTING -p udp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
            else
                echo "iptables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
                echo "iptables -t nat -A PREROUTING -p udp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
                echo "iptables -t nat -A POSTROUTING -p tcp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
                echo "iptables -t nat -A POSTROUTING -p udp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
            fi
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${Y}%-11s${NC} ${B}│${NC} ${W}%-38s${NC} ${B}│${NC}\n" "$p" "iptables" "$target_ip"
        fi
        ((port_idx++))
    done
    echo -e "  ${B}╰──────────────┴─────────────┴────────────────────────────────────────╯${NC}"
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
    [ "$fwd_engine" == "1" ] && systemctl restart haproxy 2>/dev/null
    [ "$fwd_engine" == "2" ] && systemctl restart gost 2>/dev/null
    [ "$fwd_engine" == "3" ] && apply_iptables_rules

    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read dummy
}

edit_mapping() {
    draw_header
    echo -e "\n  ${DIM}┌─[ EDIT FORWARDING MAPPINGS ]${NC}"
    local h_map=""; local g_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K\[?[0-9a-fA-F\.:]+\]?' "$H_CONF" 2>/dev/null | tr -d '[]')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K\[?[0-9a-fA-F\.:]+\]?' | tr -d '[]' | cut -d: -f1)
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- '--to-destination \K\[?[0-9a-fA-F\.:]+\]?' "$IPT_CONF" 2>/dev/null | tr -d '[]')
    
    local all_ips=$(echo -e "$h_map\n$g_map\n$ipt_map" | grep -v '^$' | sort -u)
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
        [ -f "$H_CONF" ] && t_ports+=$(grep -E "${target_ip}(:|\])" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
        [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip" | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g' | xargs)
        [ -f "$IPT_CONF" ] && t_ports+=" "$(grep "$target_ip" "$IPT_CONF" 2>/dev/null | grep -oP '--dport \K[0-9]+' | xargs)
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
                echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} | ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} | ${W}3${NC} ${DIM}❯${NC} ${Y}iptables/ip6tables${NC}"
                echo -ne "  ${C}Select Engine ❯❯ ${NC}"; read e_opt
                e_opt=$(echo "$e_opt" | tr -d '\r' | tr -d ' ')
                
                for p in $clean_ports; do
                    if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then continue; fi
                    if [ "$e_opt" == "1" ]; then
                        local srv_target=$(format_target "$target_ip" "$p")
                        (
                            flock -x 200
                            echo -e "\nfrontend ft_$p\n    bind :::${p} v4v6\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $srv_target check inter 5000" >> "$H_CONF"
                        ) 200>/var/lock/mporter_haproxy.lock
                    elif [ "$e_opt" == "2" ]; then
                        local node_str="tcp://[::]:$p/$(format_target "$target_ip" "$p")"
                        jq --arg node "$node_str" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
                    elif [ "$e_opt" == "3" ]; then
                        enable_forwarding
                        if is_ipv6 "$target_ip"; then
                            echo "ip6tables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination [${target_ip}]:$p" >> "$IPT_CONF"
                            echo "ip6tables -t nat -A PREROUTING -p udp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination [${target_ip}]:$p" >> "$IPT_CONF"
                            echo "ip6tables -t nat -A POSTROUTING -p tcp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
                            echo "ip6tables -t nat -A POSTROUTING -p udp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
                        else
                            echo "iptables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
                            echo "iptables -t nat -A PREROUTING -p udp --dport $p -m comment --comment \"MPORTER_NAT\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
                            echo "iptables -t nat -A POSTROUTING -p tcp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
                            echo "iptables -t nat -A POSTROUTING -p udp -d $target_ip --dport $p -m comment --comment \"MPORTER_NAT\" -j MASQUERADE" >> "$IPT_CONF"
                        fi
                    fi
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                [ "$e_opt" == "1" ] && systemctl restart haproxy 2>/dev/null
                [ "$e_opt" == "2" ] && systemctl restart gost 2>/dev/null
                [ "$e_opt" == "3" ] && apply_iptables_rules
                echo -e "  ${G}● Ports added successfully!${NC}"; sleep 1.5 ;;
            2)
                echo -ne "\n  ${C}●${NC} ${W}Enter Exact Ports to Remove (e.g. 80,443): ${NC}"; read raw_ports
                raw_ports=$(echo "$raw_ports" | tr -d '\r')
                clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
                for p in $clean_ports; do
                    sed -i "/frontend ft_$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/bind :::${p} /d" "$H_CONF" 2>/dev/null
                    sed -i "/bind \*:$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/default_backend bk_$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/backend bk_$p$/d" "$H_CONF" 2>/dev/null
                    sed -i "/server srv_$p /d" "$H_CONF" 2>/dev/null
                    sed -i "/server srv_${p}_[0-9]\+ /d" "$H_CONF" 2>/dev/null
                    
                    if command -v jq >/dev/null 2>&1 && [ -f "$G_CONF" ]; then 
                        jq --arg p "$p" '.ServeNodes = [.ServeNodes[]? | select(startswith("tcp://:"+$p+"/") or startswith("tcp://[::]:"+$p+"/") | not)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF" 2>/dev/null
                    fi
                    sed -i "/--dport $p /d" "$IPT_CONF" 2>/dev/null
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; apply_iptables_rules
                echo -e "  ${G}● Ports removed securely!${NC}"; sleep 1.5 ;;
            3)
                echo -ne "\n  ${C}●${NC} ${W}Enter New Destination IP (IPv4 or IPv6): ${NC}"; read new_ip
                new_ip=$(echo "$new_ip" | tr -d '\r' | tr -d ' ')
                [ -z "$new_ip" ] && continue
                echo -e "  ${DIM}● Migrating $target_ip -> $new_ip ...${NC}"
                
                [ -f "$H_CONF" ] && sed -i "s/$target_ip/$new_ip/g" "$H_CONF"
                if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
                    jq --arg old "$target_ip" --arg new "$new_ip" '.ServeNodes = [.ServeNodes[]? | sub($old; $new)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF"
                fi
                [ -f "$IPT_CONF" ] && sed -i "s/$target_ip/$new_ip/g" "$IPT_CONF"
                
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; apply_iptables_rules
                echo -e "  ${G}● IP Successfully Migrated!${NC}"; sleep 1.5
                target_ip="$new_ip"
                break ;;
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
    
    local h_map=""; local g_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | tr -d '[]' | sed 's/:.*//')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/(\[[^\]]+\]|[^:]+):([0-9]+)\/(\[[^\]]+\]|[^:]+):.*/\2 \3/g' | tr -d '[]')
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- '--dport \K[0-9]+.*--to-destination \[?[0-9a-fA-F\.:]+\]?' "$IPT_CONF" 2>/dev/null | tr -d '[]' | awk '{print $1 " " $NF}' | sort -u)
    
    local mappings=$(echo -e "$h_map\n$g_map\n$ipt_map" | grep -v '^$')
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
    
    local h_map=""; local g_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K\[?[0-9a-fA-F\.:]+\]?' "$H_CONF" 2>/dev/null | tr -d '[]')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K\[?[0-9a-fA-F\.:]+\]?' | tr -d '[]' | cut -d: -f1)
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- '--to-destination \K\[?[0-9a-fA-F\.:]+\]?' "$IPT_CONF" 2>/dev/null | tr -d '[]')
    local all_ips=$(echo -e "$h_map\n$g_map\n$ipt_map" | grep -v '^$' | sort -u)

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
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; apply_iptables_rules
                echo -e "  ${G}● Interface $selected_ifc purged successfully!${NC}"; sleep 1.5
            fi ;;
        2)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            local ip_arr=($all_ips)
            echo -e "\n  ${B}╭────────────────── Select Target IP to Purge ─────────────────╮${NC}"
            for i in "${!ip_arr[@]}"; do 
                local ifc=$(get_iface_for_ip "${ip_arr[$i]}")
                printf "  ${B}│${NC}  ${Y}%-2d${NC} ${C}❯${NC} ${W}%-25s${NC} ${DIM}(%s)${NC}                 ${B}│${NC}\n" "$i" "${ip_arr[$i]}" "$ifc"
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx
            idx=$(echo "$idx" | tr -d '\r' | tr -d ' ')
            
            local target_ip="${ip_arr[$idx]}"
            if [ -z "$target_ip" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            
            purge_ip_core "$target_ip"
            systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; apply_iptables_rules
            echo -e "  ${G}● IP $target_ip purged successfully!${NC}"; sleep 1.5 ;;
        3) 
            echo -ne "  ${R}● Wipe all active mappings globally? (y/n) ❯❯ ${NC}"; read confirm
            confirm=$(echo "$confirm" | tr -d '\r' | tr -d ' ')
            if [[ "$confirm" == "y" ]]; then
                echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
                echo -e "frontend dummy_check\n    bind :::9999 v4v6\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
                echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
                > "$IPT_CONF"
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; apply_iptables_rules
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
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Restart Gost Engine${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Re-apply iptables/ip6tables Rules${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Restart All Services${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read r_opt
    r_opt=$(echo "$r_opt" | tr -d '\r' | tr -d ' ')
    echo ""
    case $r_opt in
        1) systemctl restart haproxy 2>/dev/null; echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        2) systemctl restart gost 2>/dev/null; echo -e "  ${G}● Gost restarted successfully.${NC}" ;;
        3) apply_iptables_rules; echo -e "  ${G}● NAT rules re-applied successfully.${NC}" ;;
        4) systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; apply_iptables_rules; echo -e "  ${G}● All services refreshed.${NC}" ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    sleep 1.5
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install & Configure Engines (HAP/Gost/IPT)${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Add Port Mappings (Dual-Stack IPv4/IPv6)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Mappings (Add/Del/Migrate)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View IP -> Port Matrix${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Delete & Purge Mappings (By Interface/IP/All)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Uninstall All Mappings${NC}\n  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Smart Interface Watchdog (Auto-Cleanup)${NC}\n  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Manual Restart Services${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 30 opt
    opt=$(echo "$opt" | tr -d '\r' | tr -d ' ')
    case $opt in
        1) fix_and_install ;; 2) smart_map ;; 3) edit_mapping ;; 4) show_table ;;
        5) purge_menu ;;
        6) echo -ne "  ${R}● Wipe All Mappings & Engines? (y/n) ❯❯ ${NC}"; read confirm
           confirm=$(echo "$confirm" | tr -d '\r' | tr -d ' ')
           if [[ "$confirm" == "y" ]]; then 
               systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null
               systemctl stop gost 2>/dev/null; systemctl disable gost 2>/dev/null
               systemctl stop mporter-watchdog 2>/dev/null; systemctl disable mporter-watchdog 2>/dev/null
               rm -rf /etc/haproxy /var/lib/haproxy /etc/gost /etc/mporter /etc/systemd/system/mporter-watchdog.service
               iptables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do iptables -t nat $rule 2>/dev/null; done
               iptables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do iptables -t nat $rule 2>/dev/null; done
               ip6tables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do ip6tables -t nat $rule 2>/dev/null; done
               ip6tables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT" | sed 's/^-A /-D /' | while read -r rule; do ip6tables -t nat $rule 2>/dev/null; done
               apt-get purge -y haproxy 2>/dev/null; systemctl daemon-reload
               echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0
           fi ;;
        7) smart_watchdog_menu ;; 8) manual_restart ;; 0) clear; exit 0 ;;
    esac
done
