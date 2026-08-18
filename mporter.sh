#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v7.3.0 (Strict Auto-Distribute) ---
# [PATCHED: Flawless Purge, Migration Feature, HAProxy Wipe Fix, Watchdog Safety & Offline Local Bypass]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mporter"
H_CONF="/etc/haproxy/haproxy.cfg"
G_CONF="/etc/gost/config.json"
OBFS_DIR="/etc/mporter/obfs_rules"
LOCAL_DIR="/root/mtunnel"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# همگام‌سازی پوشه پکیج‌ها
get_pkg_dir() {
    if [ -d "$SCRIPT_DIR/packages" ]; then echo "$SCRIPT_DIR/packages"
    elif [ -d "$LOCAL_DIR/packages" ]; then echo "$LOCAL_DIR/packages"
    else echo "$LOCAL_DIR/packages"; fi
}

purge_ip_core() {
    local target_ip="$1"
    local t_ports=""
    
    [ -f "$H_CONF" ] && t_ports+=$(grep "$target_ip:" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip:" | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g' | xargs)
    t_ports=$(echo "$t_ports" | tr ' ' '\n' | grep -v '^$' | sort -un | xargs)
    
    for p in $t_ports; do
        sed -i "/frontend ft_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/bind \*:$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/default_backend bk_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/backend bk_$p$/d" "$H_CONF" 2>/dev/null
        sed -i "/server srv_$p /d" "$H_CONF" 2>/dev/null
        sed -i "/server srv_${p}_[0-9]\+ /d" "$H_CONF" 2>/dev/null
        
        if command -v jq >/dev/null 2>&1; then 
            jq --arg p "$p" '.ServeNodes = [.ServeNodes[]? | select(startswith("tcp://:"+$p+"/") | not)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF" 2>/dev/null
        fi
        
        if [ -f "$OBFS_DIR/nat.sh" ]; then 
            sed -i "/--dport $p /d" "$OBFS_DIR/nat.sh" 2>/dev/null
            sed -i "/:$p -F/d" "$OBFS_DIR/gost.sh" 2>/dev/null
        fi
    done
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
    
    if [ -f "$OBFS_DIR/nat.sh" ]; then
        sed -i "/-d $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
        sed -i "/\/$target_ip:/d" "$OBFS_DIR/gost.sh" 2>/dev/null
        sed -i "/-d $target_ip -m comment --comment \"OBFS_CNT_TX_/d" "$OBFS_DIR/nat.sh" 2>/dev/null
        sed -i "/-s $target_ip -m comment --comment \"OBFS_CNT_RX_/d" "$OBFS_DIR/nat.sh" 2>/dev/null
        sed -i "/# OBFS_CNT_TX_.*_$target_ip/d" "$OBFS_DIR/nat.sh" 2>/dev/null
    fi
    echo "$(date) | Deep Purged Target IP: $target_ip and its associated ports." >> /var/log/mporter-watchdog.log
}

# --- 🌟 BACKEND APIs 🌟 ---
if [[ "$1" == "--purge-ip" && -n "$2" ]]; then
    purge_ip_core "$2"
    systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
    [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
    exit 0
fi

if [[ "$1" == "--cleanup-orphans" ]]; then
    h_ips=$(grep -oP 'server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null | sort -u)
    g_ips=""
    if command -v jq >/dev/null 2>&1 && [ -f "$G_CONF" ]; then
        g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1 | sort -u)
    fi
    all_ips=$(echo -e "$h_ips\n$g_ips" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | sort -u)
    
    for ip in $all_ips; do
        subnet=$(echo "$ip" | cut -d'.' -f1-3)
        found=false
        grep -qR "CORE_SUBNET=$subnet" /etc/mgre/ /etc/ml2tp/ /etc/mhysteria/ 2>/dev/null && found=true
        grep -qR "$subnet" /etc/wireguard/ 2>/dev/null && found=true
        grep -qR "$ip" /etc/mbackhaul/ 2>/dev/null && found=true
        
        if [ "$found" = false ]; then
            purge_ip_core "$ip"
        fi
    done
    systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
    [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
    exit 0
fi

if [[ "$1" != "--apply" ]]; then
    if [[ ! -x "$INSTALL_PATH" ]]; then cp "$0" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH" 2>/dev/null; fi
fi

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=25; local progress=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        ((progress++)); if (( progress > 95 )); then progress=95; fi
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  %b⟳%b %b%-22s%b %b[%b%b%b%b]%b %b%3d%%%%%b" "$C" "$NC" "$W" "$text" "$NC" "$M" "$bar" "$DIM" "$empty_bar" "$M" "$NC" "$C" "$progress" "$NC"
        sleep 0.2
    done
    local bar=$(printf "%${width}s" "" | tr ' ' '#')
    printf "\r  %b✔%b %b%-22s%b %b[%b]%b %b100%%%%%b \n" "$G" "$NC" "$W" "$text" "$NC" "$G" "$bar" "$NC" "$G" "$NC"
    tput cnorm
}

ensure_gost() {
    if [ ! -f /usr/local/bin/gost ]; then
        local P_DIR=$(get_pkg_dir)
        mkdir -p "$LOCAL_DIR/packages" 2>/dev/null
        
        # بررسی باینری و فایل فشرده محلی
        if [ -s "$P_DIR/gost" ]; then
            cp -f "$P_DIR/gost" /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
        elif ls "$P_DIR"/gost*.gz 1> /dev/null 2>&1 && ! ls "$P_DIR"/gost*.tar.gz 1> /dev/null 2>&1; then
            gzip -d -c "$P_DIR"/gost*.gz > /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
        elif ls "$P_DIR"/gost*.tar.gz 1> /dev/null 2>&1; then
            tar -xzf "$P_DIR"/gost*.tar.gz -C /usr/local/bin/ gost 2>/dev/null || tar -xzf "$P_DIR"/gost*.tar.gz -C /usr/local/bin/
            chmod +x /usr/local/bin/gost
        elif [ -s "$LOCAL_DIR/gost" ]; then
            cp "$LOCAL_DIR/gost" /usr/local/bin/gost
            chmod +x /usr/local/bin/gost
        else
            wget --timeout=4 --tries=1 -qO "/tmp/gost.gz" https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz >/dev/null 2>&1
            if [ -s "/tmp/gost.gz" ]; then
                gzip -d "/tmp/gost.gz"
                mv "/tmp/gost" "$LOCAL_DIR/packages/gost" 2>/dev/null
                cp "$LOCAL_DIR/packages/gost" /usr/local/bin/gost 2>/dev/null || cp "/tmp/gost" /usr/local/bin/gost
                chmod +x /usr/local/bin/gost
            fi
        fi
    fi
}

build_obfs_runner() {
    cat <<'EOF' > /usr/local/bin/mporter-obfs.sh
#!/bin/bash
iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
[ -f /etc/mporter/obfs_rules/nat.sh ] && source /etc/mporter/obfs_rules/nat.sh 2>/dev/null
[ -f /etc/mporter/obfs_rules/gost.sh ] && source /etc/mporter/obfs_rules/gost.sh 2>/dev/null
wait
EOF
    chmod +x /usr/local/bin/mporter-obfs.sh
    cat <<'EOF' > /etc/systemd/system/mporter-obfs.service
[Unit]
Description=MPorter OBFS Stealth Engine
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mporter-obfs.sh
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable mporter-obfs >/dev/null 2>&1; systemctl restart mporter-obfs >/dev/null 2>&1
}

install_haproxy_core() {
    (
        local P_DIR=$(get_pkg_dir)
        mkdir -p /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/sbin
        touch /var/lib/haproxy/stats 2>/dev/null

        # اولویت با پکیج لوکال / باینری آماده بدون وابستگی به اینترنت
        if [ -f "$P_DIR/haproxy" ]; then
            cp -f "$P_DIR/haproxy" /usr/sbin/haproxy 2>/dev/null || cp -f "$P_DIR/haproxy" /usr/local/sbin/haproxy
            chmod +x /usr/sbin/haproxy /usr/local/sbin/haproxy 2>/dev/null
        elif ls "$P_DIR"/haproxy*.deb >/dev/null 2>&1; then
            dpkg -i "$P_DIR"/haproxy*.deb >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
        elif ls "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1; then
            dpkg -i "$LOCAL_DIR/packages"/*.deb >/dev/null 2>&1
            apt-get install -f -y >/dev/null 2>&1
        else
            apt-get install -y haproxy >/dev/null 2>&1
        fi

        if [ ! -f "$H_CONF" ]; then
            echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
            echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
        fi
        systemctl enable haproxy >/dev/null 2>&1; systemctl restart haproxy >/dev/null 2>&1
    ) &
    draw_progress_bar $! "Deploying HAProxy"
}

install_gost_core() {
    (
        ensure_gost
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
        systemctl daemon-reload; systemctl enable gost >/dev/null 2>&1; systemctl restart gost >/dev/null 2>&1
    ) &
    draw_progress_bar $! "Deploying Gost Tunnel"
}

fix_and_install() {
    echo -e "\n  ${DIM}┌─[ SELECT CORE ENGINE ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Standard Multiplexer)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} ${DIM}(Advanced Tunneling)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Both Cores${NC} ${DIM}(Dual-Core Setup)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Install ❯❯ ${NC}"; read -t 30 core_opt
    core_opt=$(echo "$core_opt" | tr -d '\r' | tr -d ' ')

    if [[ "$core_opt" =~ ^[1-3]$ ]]; then
        echo ""
        (
            local P_DIR=$(get_pkg_dir)
            sysctl -w fs.file-max=2000000 >/dev/null 2>&1
            rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock >/dev/null 2>&1
            mkdir -p "$LOCAL_DIR/packages" 2>/dev/null

            # اگر باینری یا deb لوکال وجود دارد نیازی به اتصال اینترنت apt-get نیست
            if [ -f "$P_DIR/haproxy" ] || ls "$P_DIR"/haproxy*.deb >/dev/null 2>&1; then
                dpkg --configure -a >/dev/null 2>&1
            else
                # در صورت نیاز به دانلود، با محدودیت زمانی سریع انجام می‌شود تا روی 95 درصد گیر نکند
                timeout 8 apt-get update -y -q >/dev/null 2>&1 || true
                timeout 15 apt-get install --download-only -y -q wget curl gzip jq iproute2 cron socat haproxy >/dev/null 2>&1 || true
                cp -a /var/cache/apt/archives/*.deb "$LOCAL_DIR/packages/" 2>/dev/null || true
            fi
        ) &
        draw_progress_bar $! "Preparing OS & Caching"
    fi
    case $core_opt in
        1) install_haproxy_core ;; 2) install_gost_core ;; 3) install_haproxy_core; install_gost_core ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return ;;
    esac
    echo -e "\n  ${G}● Initialization Completed Successfully.${NC}"; sleep 2
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
    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"; else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    if systemctl is-active --quiet mporter-obfs && [ -s "$OBFS_DIR/gost.sh" ]; then obfs_stat="${C}●${NC}"; raw_obfs="●"; else obfs_stat="${DIM}○${NC}"; raw_obfs="○"; fi
    
    local h_ports=0; local g_ports=0
    if [ -f "$H_CONF" ]; then h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--)); [ "$h_ports" -lt 0 ] && h_ports=0; fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_ports=$(jq '.ServeNodes | length' "$G_CONF" 2>/dev/null); [ -z "$g_ports" ] && g_ports=0; fi
    total_ports=$((h_ports + g_ports))

    local h_ips=""; local g_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1)
    
    local all_ips=$(echo -e "$h_ips\n$g_ips" | grep -v '^$' | sort -u)
    mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"
    else ip_status="${DIM}NONE${NC}"; raw_ip="NONE"; fi
}

draw_header() {
    get_stats; clear; echo ""
    raw_text=" MPorter 7.3.0 │ IP: $server_ip │ HAP: $raw_hap │ Gost: $raw_gst │ OBFS: $raw_obfs │ IPs: $raw_ip │ Pts: $total_ports "
    pad_len=$(( 92 - ${#raw_text} ))
    if (( pad_len < 0 )); then pad_len=0; fi
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter 7.3.0${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${server_ip}${NC} ${B}│${NC} ${DIM}HAP:${NC} ${hap_stat} ${B}│${NC} ${DIM}Gost:${NC} ${gst_stat} ${B}│${NC} ${DIM}OBFS:${NC} ${obfs_stat} ${B}│${NC} ${DIM}IPs:${NC} ${ip_status} ${B}│${NC} ${DIM}Pts:${NC} ${G}${total_ports}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}├──────────────┬────────────────────────────────────────────┬────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC} ${W}%-30s${NC} ${B}│${NC}\n" "INTERFACE" "TARGET NETWORK IPs" "TOTAL FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼────────────────────────────────────────────┼────────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E 'server srv_[0-9_]+ [0-9\.]+|server srv_[0-9]+ [0-9\.]+' "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1}')
    
    local ip_port_counts=$(echo -e "$h_map\n$g_map" | grep -v '^$' | awk -F'|' '{a[$1]+=$2} END {for (i in a) print i"|"a[i]}')

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
            
            local obfs_indicator=""
            if grep -q "\-d ${ips[0]} " "$OBFS_DIR/nat.sh" 2>/dev/null; then obfs_indicator=" ${M}[OBFS]${NC}"; fi
            
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${G}%-42s${NC} ${B}│${NC} ${Y}%-20s${NC} %b${B}│${NC}\n" "$iface" "$display_ips" "$total_p Mapped" "$obfs_indicator"
        done
    fi
    echo -e "  ${B}╰──────────────┴────────────────────────────────────────────┴────────────────────────────────╯${NC}"
}

smart_map() {
    draw_header
    echo -e "\n  ${DIM}┌─[ STRICT FORWARDING ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read fwd_engine
    fwd_engine=$(echo "$fwd_engine" | tr -d '\r' | tr -d ' ')
    
    if [ "$fwd_engine" != "1" ] && [ "$fwd_engine" != "2" ]; then echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; fi
    if [ "$fwd_engine" == "2" ] && ! command -v jq >/dev/null 2>&1; then echo -e "  ${R}● Gost requires 'jq'. Run Installer (1) first.${NC}"; sleep 2; return; fi

    local active_ifs=()
    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf; do [ -f "$conf" ] && active_ifs+=($(grep -E "^T_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'")); done
    for conf in /etc/mgre/vxlan/*.conf; do [ -f "$conf" ] && active_ifs+=($(grep -E "^BR_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'")); done
    for conf in /etc/ml2tp/tunnels/*.conf; do [ -f "$conf" ] && active_ifs+=($(grep -E "^T_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'")); done
    for conf in /etc/mhysteria/tunnels/*.conf; do [ -f "$conf" ] && active_ifs+=($(grep -E "^T_NAME=" "$conf" | cut -d= -f2 | tr -d '"' | tr -d "'")); done
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
    
    echo -e "\n  ${Y}● Applying Strict 1-to-1 Mappings...${NC}"
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
        elif [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
            if jq -e ".ServeNodes[] | select(. | contains(\"tcp://:$p/\"))" "$G_CONF" >/dev/null 2>&1; then skip_reason="Gost"; fi
        fi

        if [ -n "$skip_reason" ]; then
            printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "-" "Skipped (Used by $skip_reason)"
            continue
        fi
        
        # 🌟 STRICT 1-TO-1 FORWARDING with FLOCK 🌟
        if [ "$fwd_engine" == "1" ]; then
            (
                flock -x 200
                echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
            ) 200>/var/lock/mporter_haproxy.lock
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$target_ip"
        
        elif [ "$fwd_engine" == "2" ]; then
            jq --arg node "tcp://:$p/$target_ip:$p" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Gost" "$target_ip"
        fi
        ((port_idx++))
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null

    [ "$fwd_engine" == "1" ] && systemctl restart haproxy 2>/dev/null
    [ "$fwd_engine" == "2" ] && systemctl restart gost 2>/dev/null

    echo -ne "\n  ${C}●${NC} ${W}Enable Strict OBFS Stealth for these ports? (y/n): ${NC}"; read enable_obfs
    enable_obfs=$(echo "$enable_obfs" | tr -d '\r' | tr -d ' ')
    
    if [[ "$enable_obfs" == "y" ]]; then
        ensure_gost

        local remote_pub=""
        if [[ "$selected_if" != "Manual" ]]; then
            if [ -f "/etc/mgre/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mgre/tunnels/${selected_if}.conf" | cut -d= -f2)
            elif [ -f "/etc/mgre/vxlan/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mgre/vxlan/${selected_if}.conf" | cut -d= -f2)
            elif [ -f "/etc/ml2tp/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/ml2tp/tunnels/${selected_if}.conf" | cut -d= -f2)
            elif [ -f "/etc/mhysteria/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mhysteria/tunnels/${selected_if}.conf" | cut -d= -f2); fi
        fi
        
        if [ -z "$remote_pub" ]; then 
            echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP: ${NC}"; read remote_pub
            remote_pub=$(echo "$remote_pub" | tr -d '\r' | tr -d ' ')
        else 
            echo -e "  ${G}✔ Auto-detected Kharej IP: ${remote_pub}${NC}"
        fi
        
        echo -ne "  ${C}●${NC} ${W}Enter Kharej Stealth Port (Target Receiver): ${NC}"; read stealth_port
        stealth_port=$(echo "$stealth_port" | tr -d '\r' | tr -d ' ')
        echo -ne "  ${C}●${NC} ${W}Select Protocol [1: TLS | 2: WS | 3: WSS] (Default 1): ${NC}"; read t_proto
        t_proto=$(echo "$t_proto" | tr -d '\r' | tr -d ' ')
        
        local method="relay+tls"; [ "$t_proto" == "2" ] && method="relay+ws"; [ "$t_proto" == "3" ] && method="relay+wss"

        mkdir -p "$OBFS_DIR"
        local port_idx=0
        for p in $clean_ports; do
            if [ "$is_auto_all" = true ]; then
                local selected_local_ip="${selected_ips[$((port_idx % ${#selected_ips[@]}))]}"
                local base_ip=$(echo "$selected_local_ip" | cut -d'.' -f1-3); local last_octet=$(echo "$selected_local_ip" | cut -d'.' -f4)
                target_ip="${base_ip}.$((last_octet + 1))"
                [ "$last_octet" == "1" ] && target_ip="${base_ip}.2"
                [ "$last_octet" == "2" ] && target_ip="${base_ip}.1"
            fi

            local obfs_lport=$((30000 + p)); [ "$obfs_lport" -gt 65535 ] && obfs_lport=$(( p + 10000 ))
            echo "iptables -t nat -A OUTPUT -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_OBFS\" -j REDIRECT --to-ports $obfs_lport" >> "$OBFS_DIR/nat.sh"
            echo "/usr/local/bin/gost -L tcp://:$obfs_lport/$target_ip:$p -F $method://$remote_pub:$stealth_port &" >> "$OBFS_DIR/gost.sh"
            
            if ! grep -q "OBFS_CNT_TX_${selected_if}_${target_ip}" "$OBFS_DIR/nat.sh" 2>/dev/null; then
                echo "iptables -t mangle -A OUTPUT -d $target_ip -m comment --comment \"OBFS_CNT_TX_${selected_if}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                echo "iptables -t mangle -A INPUT -s $target_ip -m comment --comment \"OBFS_CNT_RX_${selected_if}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                echo "# OBFS_CNT_TX_${selected_if}_${target_ip}" >> "$OBFS_DIR/nat.sh"
            fi
            ((port_idx++))
        done
        build_obfs_runner
        echo -e "\n  ${G}● OBFS Stealth Layer configured and Ghost Counters applied!${NC}"
    fi
    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read dummy
}

edit_mapping() {
    draw_header
    echo -e "\n  ${DIM}┌─[ EDIT FORWARDING MAPPINGS ]${NC}"
    local h_map=""; local g_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1)
    
    local all_ips=$(echo -e "$h_map\n$g_map" | grep -v '^$' | sort -u)
    if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found to edit!${NC}"; sleep 2; return; fi

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
        [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip:" | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/g' | xargs)
        t_ports=$(echo "$t_ports" | tr ' ' '\n' | grep -v '^$' | sort -un | xargs)
        
        local obfs_status="${R}DISABLED${NC}"; local has_obfs=false
        if grep -q "\-d $target_ip " "$OBFS_DIR/nat.sh" 2>/dev/null; then obfs_status="${G}ENABLED${NC}"; has_obfs=true; fi

        echo -e "\n  ${DIM}┌─[ EDITING: ${W}$target_ip${DIM} ]${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Active Ports:${NC} ${Y}${t_ports:-None}${NC}\n  ${DIM}│${NC} ${DIM}OBFS Stealth:${NC} ${obfs_status}"
        echo -e "  ${DIM}├──────────────────────────────────────────────${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Add New Ports${NC} ${DIM}(Forward extra ports to this IP)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Remove Specific Ports${NC}"
        
        if [ "$has_obfs" = true ]; then echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Disable OBFS Stealth for this IP${NC}"
        else echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Enable OBFS Stealth for this IP${NC}"; fi
        
        # 🌟 NEW MIGRATE OPTION 🌟
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Migrate Target IP${NC} ${DIM}(Move ports to a new IP)${NC}"
        
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
                echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} | ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC}"
                echo -ne "  ${C}Select Engine ❯❯ ${NC}"; read e_opt
                e_opt=$(echo "$e_opt" | tr -d '\r' | tr -d ' ')
                
                for p in $clean_ports; do
                    if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then continue; fi
                    if [ "$e_opt" == "1" ]; then
                        (
                            flock -x 200
                            echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
                        ) 200>/var/lock/mporter_haproxy.lock
                    elif [ "$e_opt" == "2" ]; then jq --arg node "tcp://:$p/$target_ip:$p" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"; fi
                    
                    if [ "$has_obfs" = true ]; then
                        local ex_gost=$(grep "$target_ip:" "$OBFS_DIR/gost.sh" | head -n 1)
                        local remote_pub=$(echo "$ex_gost" | grep -oP '://\K[0-9\.]+'); local stealth_port=$(echo "$ex_gost" | grep -oP "$remote_pub:\K[0-9]+")
                        local method=$(echo "$ex_gost" | grep -oP -- '-F \K[a-z\+]+')
                        local obfs_lport=$((30000 + p)); [ "$obfs_lport" -gt 65535 ] && obfs_lport=$(( p + 10000 ))
                        echo "iptables -t nat -A OUTPUT -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_OBFS\" -j REDIRECT --to-ports $obfs_lport" >> "$OBFS_DIR/nat.sh"
                        echo "/usr/local/bin/gost -L tcp://:$obfs_lport/$target_ip:$p -F $method://$remote_pub:$stealth_port &" >> "$OBFS_DIR/gost.sh"
                    fi
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                [ "$e_opt" == "1" ] && systemctl restart haproxy 2>/dev/null; [ "$e_opt" == "2" ] && systemctl restart gost 2>/dev/null
                [ "$has_obfs" = true ] && build_obfs_runner
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
                    
                    if command -v jq >/dev/null 2>&1; then 
                        jq --arg p "$p" '.ServeNodes = [.ServeNodes[]? | select(startswith("tcp://:"+$p+"/") | not)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF" 2>/dev/null
                    fi
                    if [ -f "$OBFS_DIR/nat.sh" ]; then 
                        sed -i "/--dport $p /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                        sed -i "/:$p -F/d" "$OBFS_DIR/gost.sh" 2>/dev/null
                    fi
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; build_obfs_runner
                echo -e "  ${G}● Ports removed securely!${NC}"; sleep 1.5 ;;
            3)
                if [ "$has_obfs" = true ]; then
                    sed -i "/-d $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    sed -i "/\/$target_ip:/d" "$OBFS_DIR/gost.sh" 2>/dev/null
                    local selected_if=$(get_iface_for_ip "$target_ip")
                    sed -i "/OBFS_CNT_TX_${selected_if}_${target_ip}/d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    sed -i "/OBFS_CNT_TX_${selected_if}.*-d $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    sed -i "/OBFS_CNT_RX_${selected_if}.*-s $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    build_obfs_runner; echo -e "  ${G}● OBFS Disabled for $target_ip.${NC}"; sleep 1.5
                else
                    local selected_if=$(get_iface_for_ip "$target_ip")
                    local remote_pub=""
                    if [ -f "/etc/mgre/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mgre/tunnels/${selected_if}.conf" | cut -d= -f2)
                    elif [ -f "/etc/mgre/vxlan/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mgre/vxlan/${selected_if}.conf" | cut -d= -f2)
                    elif [ -f "/etc/ml2tp/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/ml2tp/tunnels/${selected_if}.conf" | cut -d= -f2)
                    elif [ -f "/etc/mhysteria/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mhysteria/tunnels/${selected_if}.conf" | cut -d= -f2); fi
                    
                    if [ -z "$remote_pub" ]; then 
                        echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP: ${NC}"; read remote_pub
                        remote_pub=$(echo "$remote_pub" | tr -d '\r' | tr -d ' ')
                    else 
                        echo -e "  ${G}✔ Auto-detected Kharej IP: ${remote_pub}${NC}"
                    fi
                    
                    echo -ne "  ${C}●${NC} ${W}Enter Kharej Stealth Port: ${NC}"; read stealth_port
                    stealth_port=$(echo "$stealth_port" | tr -d '\r' | tr -d ' ')
                    echo -ne "  ${C}●${NC} ${W}Select Protocol [1: TLS | 2: WS | 3: WSS] (Default 1): ${NC}"; read t_proto
                    t_proto=$(echo "$t_proto" | tr -d '\r' | tr -d ' ')
                    
                    local method="relay+tls"; [ "$t_proto" == "2" ] && method="relay+ws"; [ "$t_proto" == "3" ] && method="relay+wss"

                    mkdir -p "$OBFS_DIR"
                    ensure_gost

                    for p in $t_ports; do
                        local obfs_lport=$((30000 + p)); [ "$obfs_lport" -gt 65535 ] && obfs_lport=$(( p + 10000 ))
                        echo "iptables -t nat -A OUTPUT -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_OBFS\" -j REDIRECT --to-ports $obfs_lport" >> "$OBFS_DIR/nat.sh"
                        echo "/usr/local/bin/gost -L tcp://:$obfs_lport/$target_ip:$p -F $method://$remote_pub:$stealth_port &" >> "$OBFS_DIR/gost.sh"
                    done
                    if ! grep -q "OBFS_CNT_TX_${selected_if}_${target_ip}" "$OBFS_DIR/nat.sh" 2>/dev/null; then
                        echo "iptables -t mangle -A OUTPUT -d $target_ip -m comment --comment \"OBFS_CNT_TX_${selected_if}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                        echo "iptables -t mangle -A INPUT -s $target_ip -m comment --comment \"OBFS_CNT_RX_${selected_if}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                        echo "# OBFS_CNT_TX_${selected_if}_${target_ip}" >> "$OBFS_DIR/nat.sh"
                    fi
                    build_obfs_runner; echo -e "  ${G}● OBFS Enabled for $target_ip.${NC}"; sleep 1.5
                fi ;;
            4)
                # 🌟 MIGRATION LOGIC 🌟
                echo -ne "\n  ${C}●${NC} ${W}Enter New Destination IP: ${NC}"; read new_ip
                new_ip=$(echo "$new_ip" | tr -d '\r' | tr -d ' ')
                if ! [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; continue
                fi
                echo -e "  ${DIM}● Migrating $target_ip -> $new_ip ...${NC}"
                
                if [ -f "$H_CONF" ]; then
                    sed -i "s/ $target_ip:/ $new_ip:/g" "$H_CONF"
                fi
                
                if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
                    jq --arg old "/$target_ip:" --arg new "/$new_ip:" '.ServeNodes = [.ServeNodes[]? | sub($old; $new)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF"
                fi
                
                if [ -f "$OBFS_DIR/nat.sh" ]; then
                    sed -i "s/\b${target_ip}\b/${new_ip}/g" "$OBFS_DIR/nat.sh"
                fi
                if [ -f "$OBFS_DIR/gost.sh" ]; then
                    sed -i "s/\b${target_ip}\b/${new_ip}/g" "$OBFS_DIR/gost.sh"
                fi
                
                systemctl restart haproxy 2>/dev/null
                systemctl restart gost 2>/dev/null
                [ -f "$OBFS_DIR/nat.sh" ] && build_obfs_runner
                
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
    
    local h_map=""; local g_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {print port " " $3}' | sed 's/:.*//')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/([0-9\.]+):.*/\1 \2/g')
    
    local mappings=$(echo -e "$h_map\n$g_map" | grep -v '^$')
    if [ -z "$mappings" ]; then printf "  ${B}│${NC} ${DIM}%-88s${NC} ${B}│${NC}\n" "  No active mappings."
    else
        declare -A ip_ports_arr
        while read -r p_num d_ip; do if [ -n "$d_ip" ]; then ip_ports_arr["$d_ip"]+="$p_num, "; fi; done <<< "$mappings"
        for d_ip in $(for i in "${!ip_ports_arr[@]}"; do echo $i; done | sort); do
            iface=$(get_iface_for_ip "$d_ip")
            raw_ports="${ip_ports_arr[$d_ip]}"; raw_ports="${raw_ports%, }"
            local display_ports=""
            for p in $(echo "$raw_ports" | tr ',' ' '); do
                if grep -q "dport $p " "$OBFS_DIR/nat.sh" 2>/dev/null; then display_ports+="${M}${p}*(OBFS)${Y}, "
                else display_ports+="${p}, "; fi
            done
            display_ports="${display_ports%, }"
            local clean_str=$(echo -e "$display_ports" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            if [ ${#clean_str} -gt 30 ]; then display_ports="${clean_str:0:27}..."; clean_str="$display_ports"; fi
            local pad=$(printf '%*s' "$((30 - ${#clean_str}))" "")
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${G}%-42s${NC} ${B}│${NC} ${Y}%s%s${NC} ${B}│${NC}\n" "$iface" "$d_ip" "$display_ports" "$pad"
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
    
    local h_map=""; local g_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1)
    local all_ips=$(echo -e "$h_map\n$g_map" | grep -v '^$' | sort -u)

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
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
                [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
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
            systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
            [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
            echo -e "  ${G}● IP $target_ip purged successfully!${NC}"; sleep 1.5 ;;
        3) 
            echo -ne "  ${R}● Wipe all active mappings globally? (y/n) ❯❯ ${NC}"; read confirm
            confirm=$(echo "$confirm" | tr -d '\r' | tr -d ' ')
            if [[ "$confirm" == "y" ]]; then
                echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
                echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
                echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
                rm -rf "$OBFS_DIR"
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null
                build_obfs_runner
                echo -e "  ${G}● All global mappings wiped. Core configs preserved.${NC}"; sleep 1.5
            fi ;;
        0) return ;;
    esac
}

setup_watchdog() {
    cat <<'EOF' > /usr/local/bin/mporter-watchdog.sh
#!/bin/bash
while true; do
    sleep 30
    /usr/bin/mporter --cleanup-orphans >/dev/null 2>&1
done
EOF
    chmod +x /usr/local/bin/mporter-watchdog.sh
    cat <<'EOF' > /etc/systemd/system/mporter-watchdog.service
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
EOF
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
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Restart Gost Engine${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${G}Restart Both Engines${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read r_opt
    r_opt=$(echo "$r_opt" | tr -d '\r' | tr -d ' ')
    echo ""
    case $r_opt in
        1) systemctl restart haproxy 2>/dev/null; echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        2) systemctl restart gost 2>/dev/null; echo -e "  ${G}● Gost restarted successfully.${NC}" ;;
        3) systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; echo -e "  ${G}● Both engines restarted successfully.${NC}" ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    sleep 1.5
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ ACTIONS ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Install & Configure Core Engines${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Add Port Mappings (Strict 1-to-1)${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Edit Mappings (Add/Del/OBFS)${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View IP -> Port Matrix (OBFS Stats)${NC}\n  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Delete & Purge Mappings (By Interface/IP/All)${NC}\n  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Uninstall Everything (Nuclear Wipe)${NC}\n  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Smart Interface Watchdog (Auto-Cleanup)${NC}\n  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Manual Restart Services${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"
    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 30 opt
    opt=$(echo "$opt" | tr -d '\r' | tr -d ' ')
    case $opt in
        1) fix_and_install ;; 2) smart_map ;; 3) edit_mapping ;; 4) show_table ;;
        5) purge_menu ;;
        6) echo -ne "  ${R}● Nuclear Wipe? (y/n) ❯❯ ${NC}"; read confirm
           confirm=$(echo "$confirm" | tr -d '\r' | tr -d ' ')
           if [[ "$confirm" == "y" ]]; then 
               systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null
               systemctl stop gost 2>/dev/null; systemctl disable gost 2>/dev/null
               systemctl stop mporter-obfs 2>/dev/null; systemctl disable mporter-obfs 2>/dev/null
               systemctl stop mporter-watchdog 2>/dev/null; systemctl disable mporter-watchdog 2>/dev/null
               rm -rf /etc/haproxy /var/lib/haproxy /usr/local/bin/gost /etc/gost /etc/systemd/system/gost.service "$OBFS_DIR" /etc/systemd/system/mporter-obfs.service /etc/systemd/system/mporter-watchdog.service
               apt-get purge -y haproxy 2>/dev/null; systemctl daemon-reload
               iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
               iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0
           fi ;;
        7) smart_watchdog_menu ;; 8) manual_restart ;; 0) clear; exit 0 ;;
    esac
done
