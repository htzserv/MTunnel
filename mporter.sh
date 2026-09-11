#!/bin/bash
# --- MDesign Modular Core (mporter.sh) | MPorter Manager v8.3.19 ---
# [Features: Fixed Global Scope Variables | Async OTA Badge | Stable Logic]

MODULE_VERSION="8.3.19"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; W='\033[1;37m'; C='\033[0;36m'; M='\033[1;35m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mporter"
H_CONF="/etc/haproxy/haproxy.cfg"
G_CONF="/etc/gost/config.json"
OBFS_DIR="/etc/mporter/obfs_rules"
IPT_DIR="/etc/mporter/iptables_core"
IPT_CONF="$IPT_DIR/rules.sh"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

mkdir -p "$LOCAL_DIR/packages" /etc/haproxy /var/lib/haproxy /etc/gost "$OBFS_DIR" "$IPT_DIR" /usr/sbin /usr/local/sbin /usr/local/bin 2>/dev/null
touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null

if [ -f "$0" ] && [ "$0" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/mporter.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/mporter.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fkSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO- --no-check-certificate --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.mporter_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local rel_path="mporter.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.mporter_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.mporter_remote_ver" | tr -d '\r\n ')

    clear; echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (Script Only) ]${NC}"
    
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        echo -e "  ${DIM}├─${NC} ${Y}Update Available: v${MODULE_VERSION} ➔ v${remote_v}${NC}"
    else
        echo -e "  ${DIM}├─${NC} ${DIM}Current Version: v${MODULE_VERSION}${NC}"
    fi

    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Official GitHub Server${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read src_opt
    
    local tmp_file="$SECURE_TMP/.mporter_update.$$"
    local dl_success=false

    if [[ "$src_opt" == "4" ]]; then
        > "$tmp_file"
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
        dl_success=true
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) 
               echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read custom_url
               dl_url=$(echo "$custom_url" | tr -d '\r' | tr -d ' ')
               [ -z "$dl_url" ] && return
               ;;
        esac

        echo -e "\n  ${C}⟳${NC} ${W}Downloading MPorter Update...${NC}"
        
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp_file" "$dl_url" 2>/dev/null && dl_success=true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null && dl_success=true
        fi
    else
        return
    fi

    if [ "$dl_success" = true ] && [ -s "$tmp_file" ] && grep -q "#!/bin/bash" "$tmp_file"; then
        local new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"

        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read confirm

        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled by user.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. File not found or network timeout.${NC}"
        rm -f "$tmp_file"
        sleep 3
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_progress_bar() {
    local pid=$1; local text=$2; local width=28; local progress=0
    local ticks=0; local max_ticks=480
    tput civis 2>/dev/null || true
    
    while kill -0 "$pid" 2>/dev/null; do
        ((progress++)); [ "$progress" -gt 95 ] && progress=95
        local filled=$(( progress * width / 100 )); local empty=$(( width - filled ))
        local bar=$(printf "%${filled}s" "" | tr ' ' '#'); local empty_bar=$(printf "%${empty}s" "" | tr ' ' '-')
        printf "\r  ${C}⟳${NC} ${W}%-26s${NC} ${B}[${G}%s${DIM}%s${B}]${NC} ${C}%3d%%${NC}" "$text" "$bar" "$empty_bar" "$progress"
        sleep 0.25
        ((ticks++))
        
        if [ "$ticks" -gt "$max_ticks" ]; then
            kill -9 "$pid" 2>/dev/null || true
            printf "\r  ${R}✖${NC} ${W}%-26s${NC} ${R}[ TIMEOUT KILLED ]${NC}           \n" "$text"
            tput cnorm 2>/dev/null || true
            return 1
        fi
    done
    wait "$pid" 2>/dev/null || true
    local bar=$(printf "%${width}s" "" | tr ' ' '#')
    printf "\r  ${G}✔${NC} ${W}%-26s${NC} ${B}[${G}%s${B}]${NC} ${G}100%%${NC}\n" "$text" "$bar"
    tput cnorm 2>/dev/null || true
}

purge_ip_core() {
    local target_ip=$(echo "$1" | tr -dc '0-9.')
    if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return; fi
    
    local t_ports=""
    [ -f "$H_CONF" ] && t_ports+=$(grep "$target_ip:" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip:" | grep -oP 'tcp://:\K[0-9]+' | xargs)
    [ -f "$IPT_CONF" ] && t_ports+=" "$(grep "MPORTER_NAT_$target_ip" "$IPT_CONF" 2>/dev/null | grep "PREROUTING" | grep -oP -- '--dport \K[0-9]+' | xargs)
    
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
        
        if [ -f "$IPT_CONF" ]; then
            sed -i "/--dport $p .*MPORTER_NAT_$target_ip/d" "$IPT_CONF" 2>/dev/null
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
}

if [[ "$1" == "--purge-ip" && -n "$2" ]]; then
    purge_ip_core "$2"
    systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
    [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
    exit 0
fi

if [[ "$1" == "--cleanup-orphans" ]]; then
    h_ips=$(grep -oP 'server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null | sort -u)
    g_ips=""
    ipt_ips=""
    if command -v jq >/dev/null 2>&1 && [ -f "$G_CONF" ]; then
        g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1 | sort -u)
    fi
    [ -f "$IPT_CONF" ] && ipt_ips=$(grep -oP 'MPORTER_NAT_\K[0-9\.]+' "$IPT_CONF" 2>/dev/null | sort -u)
    
    all_ips=$(echo -e "$h_ips\n$g_ips\n$ipt_ips" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | sort -u)
    
    for ip in $all_ips; do
        subnet=$(echo "$ip" | cut -d'.' -f1-3)
        found=false
        grep -qR "CORE_SUBNET=$subnet" /etc/mgre/ /etc/ml2tp/ /etc/mhysteria/ 2>/dev/null && found=true
        grep -qR "$subnet" /etc/wireguard/ 2>/dev/null && found=true
        grep -qR "$ip" /etc/mbackhaul/ /etc/paqet/ 2>/dev/null && found=true
        
        if [ "$found" = false ]; then purge_ip_core "$ip"; fi
    done
    systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
    [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
    exit 0
fi

build_iptables_runner() {
    cat <<'EOF_IPT' > /usr/local/bin/mporter-iptables.sh
#!/bin/bash
iptables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read -r rule; do eval iptables -t nat $rule 2>/dev/null; done
iptables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read -r rule; do eval iptables -t nat $rule 2>/dev/null; done
[ -f /etc/mporter/iptables_core/rules.sh ] && source /etc/mporter/iptables_core/rules.sh 2>/dev/null
EOF_IPT
    chmod +x /usr/local/bin/mporter-iptables.sh
    
    cat <<'EOF_SRV_IPT' > /etc/systemd/system/mporter-iptables.service
[Unit]
Description=MPorter Kernel NAT Engine
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mporter-iptables.sh
[Install]
WantedBy=multi-user.target
EOF_SRV_IPT
    systemctl daemon-reload; systemctl enable mporter-iptables >/dev/null 2>&1; systemctl restart mporter-iptables >/dev/null 2>&1
}

build_obfs_runner() {
    cat <<'EOF_OBFS' > /usr/local/bin/mporter-obfs.sh
#!/bin/bash
iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
[ -f /etc/mporter/obfs_rules/nat.sh ] && source /etc/mporter/obfs_rules/nat.sh 2>/dev/null
[ -f /etc/mporter/obfs_rules/gost.sh ] && source /etc/mporter/obfs_rules/gost.sh 2>/dev/null

if [ -n "$(jobs -p)" ]; then wait; else sleep infinity; fi
EOF_OBFS
    chmod +x /usr/local/bin/mporter-obfs.sh
    cat <<'EOF_SRV' > /etc/systemd/system/mporter-obfs.service
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
EOF_SRV
    systemctl daemon-reload; systemctl enable mporter-obfs >/dev/null 2>&1; systemctl restart mporter-obfs >/dev/null 2>&1
}

install_core_engines() {
    clear; echo ""
    echo -e "  ${DIM}┌─[ ENGINE SELECTION (Select Cores to Install) ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy Engine Only${NC} ${DIM}(Load Balancer / Stable)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost Engine Only${NC} ${DIM}(TLS/WS Obfuscator)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Iptables NAT Engine Only${NC} ${DIM}(Raw Speed)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Install ALL Engines (Tri-Core)${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    
    echo -ne "  ${C}Select Option ❯❯ ${NC}"; read eng_opt
    if [[ ! "$eng_opt" =~ ^[1-4]$ ]]; then return; fi
    
    echo -e "\n  ${DIM}┌─[ INITIALIZING INSTALLATION ]${NC}"
    
    (
        sysctl -w fs.file-max=2000000 >/dev/null 2>&1
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null; echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        killall -9 apt-get apt dpkg 2>/dev/null || true
        rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >/dev/null 2>&1 || true
        timeout 45 apt-get update -o Acquire::ForceIPv4=true -y -q >/dev/null 2>&1 || true
        timeout 60 apt-get install -o Acquire::ForceIPv4=true -y -q jq curl wget >/dev/null 2>&1 || true
    ) &
    draw_progress_bar $! "Resolving Dependencies"

    if [[ "$eng_opt" == "4" || "$eng_opt" == "1" ]]; then
        (
            mkdir -p /etc/haproxy /var/lib/haproxy /usr/sbin /usr/local/sbin 2>/dev/null
            touch /var/lib/haproxy/stats 2>/dev/null
            timeout 60 apt-get install -o Acquire::ForceIPv4=true -y --no-install-recommends liblua5.4-0 haproxy >/dev/null 2>&1 || true
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
            systemctl daemon-reload >/dev/null 2>&1
            systemctl unmask haproxy >/dev/null 2>&1
            systemctl enable haproxy >/dev/null 2>&1
            systemctl restart haproxy >/dev/null 2>&1 || true
        ) &
        draw_progress_bar $! "Deploying HAProxy Engine"
    fi

    if [[ "$eng_opt" == "4" || "$eng_opt" == "2" ]]; then
        (
            if [ ! -f /usr/local/bin/gost ]; then
                local G_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
                local G_PROXY="https://ghproxy.net/"
                local dl_ok=false
                if command -v curl >/dev/null 2>&1; then
                    curl -fsSL --connect-timeout 10 --max-time 60 -o "/tmp/gost.gz" "$G_URL" 2>/dev/null && dl_ok=true
                    [ "$dl_ok" = false ] && curl -fsSL --connect-timeout 10 --max-time 60 -o "/tmp/gost.gz" "${G_PROXY}${G_URL}" 2>/dev/null && dl_ok=true
                elif command -v wget >/dev/null 2>&1; then
                    wget -q --timeout=15 --tries=2 -O "/tmp/gost.gz" "$G_URL" 2>/dev/null && dl_ok=true
                    [ "$dl_ok" = false ] && wget -q --timeout=15 --tries=2 -O "/tmp/gost.gz" "${G_PROXY}${G_URL}" 2>/dev/null && dl_ok=true
                fi
                
                if [ -s "/tmp/gost.gz" ]; then
                    gzip -d "/tmp/gost.gz"
                    mv "/tmp/gost" /usr/local/bin/gost 2>/dev/null
                    chmod +x /usr/local/bin/gost
                fi
            fi
            mkdir -p /etc/gost 2>/dev/null
            if [ ! -f "$G_CONF" ] || ! jq . "$G_CONF" >/dev/null 2>&1; then echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"; fi
            cat <<EOF_GST > /etc/systemd/system/gost.service
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
        ) &
        draw_progress_bar $! "Deploying Gost Engine"
    fi

    if [[ "$eng_opt" == "4" || "$eng_opt" == "3" ]]; then
        (
            mkdir -p "$IPT_DIR" 2>/dev/null
            touch "$IPT_CONF" 2>/dev/null; chmod +x "$IPT_CONF" 2>/dev/null
            build_iptables_runner
        ) &
        draw_progress_bar $! "Deploying Kernel NAT Engine"
    fi

    echo -e "  ${DIM}└──────────────────────────────────────────────────────────┘${NC}\n"
    sleep 1
}

get_iface_info() {
    local target_ip=$1
    local iface=$(ip route get "$target_ip" 2>/dev/null | head -n 1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    
    if [ -z "$iface" ] || [ "$iface" == "lo" ]; then
        local subnet=$(echo "$target_ip" | cut -d'.' -f1-3)
        local check_iface=$(ip -o -4 addr show 2>/dev/null | grep -w "${subnet}\." | awk '{print $2}' | head -n 1)
        [ -n "$check_iface" ] && iface="$check_iface"
    fi

    local t_type="System"
    local t_name="$iface"

    if [[ "$iface" == greir* ]]; then t_type="GRE"; t_name="${iface#greir}"
    elif [[ "$iface" == grekh* ]]; then t_type="GRE"; t_name="${iface#grekh}"
    elif [[ "$iface" == gre6ir* ]]; then t_type="IP6GRE"; t_name="${iface#gre6ir}"
    elif [[ "$iface" == gre6kh* ]]; then t_type="IP6GRE"; t_name="${iface#gre6kh}"
    elif [[ "$iface" == vx_* ]]; then t_type="VXLAN"; t_name="${iface#vx_}"
    elif [[ "$iface" == br_* ]]; then t_type="VXLAN"; t_name="${iface#br_}"
    elif [[ "$iface" == bh_* ]]; then t_type="BACKHAUL"; t_name="${iface#bh_}"
    elif [[ "$iface" == rh_* ]]; then t_type="RATHOLE"; t_name="${iface#rh_}"
    elif [[ "$iface" == rt_* ]]; then t_type="RATHOLE"; t_name="${iface#rt_}"
    elif [[ "$iface" == pq_* ]]; then t_type="PAQET"; t_name="${iface#pq_}"
    elif [[ "$iface" == l2tp_* ]]; then t_type="L2TP"; t_name="${iface#l2tp_}"
    elif [[ "$iface" == hys_* ]]; then t_type="HYSTERIA"; t_name="${iface#hys_}"
    elif [ "$target_ip" == "127.0.0.1" ]; then t_type="Local"; t_name="Loopback"
    else [ -z "$t_name" ] && t_name="Unknown"; fi

    echo "${t_type}|${t_name}"
}

format_engine() {
    local raw="$1"
    local e_list=()
    [[ "$raw" == *"HAP"* ]] && e_list+=("${C}HAProxy${NC}")
    [[ "$raw" == *"GST"* ]] && e_list+=("${M}Gost${NC}")
    [[ "$raw" == *"IPT"* ]] && e_list+=("${Y}KernelNAT${NC}")
    [[ "$raw" == *"TUN"* ]] && e_list+=("${G}CoreNAT${NC}")
    
    local res=""
    for ((i=0; i<${#e_list[@]}; i++)); do
        res+="${e_list[$i]}"
        [ $i -lt $(( ${#e_list[@]} - 1 )) ] && res+=" ${DIM}/${NC} "
    done
    echo "$res"
}

get_stats() {
    server_ip=$(get_local_ip)
    if systemctl is-active --quiet haproxy; then hap_stat="${G}●${NC}"; raw_hap="●"; else hap_stat="${DIM}○${NC}"; raw_hap="○"; fi
    if systemctl is-active --quiet gost; then gst_stat="${M}●${NC}"; raw_gst="●"; else gst_stat="${DIM}○${NC}"; raw_gst="○"; fi
    if systemctl is-active --quiet mporter-iptables; then ipt_stat="${Y}●${NC}"; raw_ipt="●"; else ipt_stat="${DIM}○${NC}"; raw_ipt="○"; fi
    
    local h_ports=0; local g_ports=0; local ipt_ports=0; local ext_ports_count=0
    if [ -f "$H_CONF" ]; then h_ports=$(grep -c -w "frontend" "$H_CONF" 2>/dev/null); ((h_ports--)); [ "$h_ports" -lt 0 ] && h_ports=0; fi
    if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then g_ports=$(jq '.ServeNodes | length' "$G_CONF" 2>/dev/null); [ -z "$g_ports" ] && g_ports=0; fi
    if [ -f "$IPT_CONF" ]; then ipt_ports=$(grep -c "PREROUTING" "$IPT_CONF" 2>/dev/null); fi
    
    local h_ips=""; local g_ips=""; local ipt_ips=""; local ext_ips=""
    [ -f "$H_CONF" ] && h_ips=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_ips=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1)
    [ -f "$IPT_CONF" ] && ipt_ips=$(grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' "$IPT_CONF" 2>/dev/null | sort -u)

    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        local TYPE="" FWD_TCP="" FWD_UDP="" CORE_SUBNET="" TUN_ID="" VNI_ID=""
        source "$conf" 2>/dev/null
        [ "$TYPE" != "1" ] && continue
        
        local t_ip=""
        if [ -n "$TUN_ID" ]; then t_ip="${CORE_SUBNET:-10.76.${TUN_ID}}.2"
        elif [ -n "$VNI_ID" ]; then t_ip="${CORE_SUBNET:-10.88.${VNI_ID}}.2"; fi
        
        local count=$(echo "$FWD_TCP,$FWD_UDP" | tr ',' '\n' | grep -v '^$' | sort -u | wc -l)
        if [ "$count" -gt 0 ]; then
            ext_ports_count=$((ext_ports_count + count))
            ext_ips+="$t_ip\n"
        fi
    done
    shopt -u nullglob

    total_ports=$((h_ports + g_ports + ipt_ports + ext_ports_count))
    local all_ips=$(echo -e "$h_ips\n$g_ips\n$ipt_ips\n$ext_ips" | grep -v '^$' | sort -u)
    mapped_ips=$(echo "$all_ips" | grep -v '^$' | wc -l)
    
    if [ "$mapped_ips" -gt 0 ]; then ip_status="${G}${mapped_ips} ACTIVE${NC}"; raw_ip="${mapped_ips} ACTIVE"
    else ip_status="${DIM}NONE${NC}"; raw_ip="NONE"; fi
}

draw_header() {
    get_stats; clear; echo ""
    raw_text=" MPorter v${MODULE_VERSION} │ IP: $server_ip │ HAP: $raw_hap │ Gost: $raw_gst │ IPT: $raw_ipt │ IPs: $raw_ip │ Pts: $total_ports "
    pad_len=$(( 106 - ${#raw_text} ))
    if (( pad_len < 0 )); then pad_len=0; fi
    padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC} ${W}MPorter v${MODULE_VERSION}${NC} ${B}│${NC} ${DIM}IP:${NC} ${W}${server_ip}${NC} ${B}│${NC} ${DIM}HAP:${NC} ${hap_stat} ${B}│${NC} ${DIM}Gost:${NC} ${gst_stat} ${B}│${NC} ${DIM}IPT:${NC} ${ipt_stat} ${B}│${NC} ${DIM}IPs:${NC} ${ip_status} ${B}│${NC} ${DIM}Pts:${NC} ${G}${total_ports}${NC}${padding}${B}│${NC}"
    echo -e "  ${B}├──────────────┬──────────┬────────────────────────────┬──────────────────────┬────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC} ${W}%-20s${NC} ${B}│${NC} ${W}%-26s${NC} ${B}│${NC}\n" "TUNNEL NAME" "TYPE" "TARGET NETWORK IPs" "ENGINES" "DISTRIBUTION"
    echo -e "  ${B}├──────────────┼──────────┼────────────────────────────┼──────────────────────┼────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""; local ipt_map=""; local ext_map_raw=""
    [ -f "$H_CONF" ] && h_map=$(grep -E 'server srv_[0-9_]+ [0-9\.]+|server srv_[0-9]+ [0-9\.]+' "$H_CONF" 2>/dev/null | awk '{print $3}' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1 "|HAP"}')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1 | sort | uniq -c | awk '{print $2 "|" $1 "|GST"}')
    [ -f "$IPT_CONF" ] && ipt_map=$(grep "PREROUTING" "$IPT_CONF" 2>/dev/null | grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' | sort | uniq -c | awk '{print $2 "|" $1 "|IPT"}')

    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        local TYPE="" FWD_TCP="" FWD_UDP="" CORE_SUBNET="" TUN_ID="" VNI_ID=""
        source "$conf" 2>/dev/null
        [ "$TYPE" != "1" ] && continue
        local t_ip=""
        if [ -n "$TUN_ID" ]; then t_ip="${CORE_SUBNET:-10.76.${TUN_ID}}.2"
        elif [ -n "$VNI_ID" ]; then t_ip="${CORE_SUBNET:-10.88.${VNI_ID}}.2"; fi
        
        local count=$(echo "$FWD_TCP,$FWD_UDP" | tr ',' '\n' | grep -v '^$' | sort -u | wc -l)
        if [ "$count" -gt 0 ]; then ext_map_raw+="${t_ip}|${count}|TUN\n"; fi
    done
    shopt -u nullglob

    local ip_port_counts=$(echo -e "$h_map\n$g_map\n$ipt_map\n$ext_map_raw" | grep -v '^$' | awk -F'|' '{
        a[$1]+=$2; 
        if(eng[$1] == "") eng[$1]=$3; else if(index(eng[$1], $3) == 0) eng[$1]=eng[$1] "/" $3
    } END {for (i in a) print i"|"a[i]"|"eng[i]}')

    if [ -z "$ip_port_counts" ] || [ "$ip_port_counts" == "|" ]; then
        printf "  ${B}│${NC} ${DIM}%-104s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A iface_ips_arr; declare -A iface_ports_arr; declare -A iface_eng_arr
        while IFS='|' read -r ip count engs; do
            if [ -n "$ip" ]; then
                local iface_info=$(get_iface_info "$ip")
                iface_ips_arr["$iface_info"]+="$ip "
                iface_ports_arr["$iface_info"]=$(( iface_ports_arr["$iface_info"] + count ))
                
                IFS='/' read -ra eng_list <<< "$engs"
                for e in "${eng_list[@]}"; do
                    if [[ ! "${iface_eng_arr["$iface_info"]}" == *"$e"* ]]; then
                        iface_eng_arr["$iface_info"]+="$e/"
                    fi
                done
            fi
        done <<< "$ip_port_counts"
        
        for iface_info in $(for i in "${!iface_ips_arr[@]}"; do echo "$i"; done | sort); do
            local t_type="${iface_info%%|*}"
            local t_name="${iface_info##*|}"
            local clean_name="${t_name}"
            [ ${#clean_name} -gt 12 ] && clean_name="${clean_name:0:9}..."
            
            ips=(${iface_ips_arr["$iface_info"]})
            total_p=${iface_ports_arr["$iface_info"]}
            
            if [ ${#ips[@]} -gt 2 ]; then display_ips="${ips[0]}, ${ips[1]}, ..."
            elif [ ${#ips[@]} -eq 2 ]; then display_ips="${ips[0]}, ${ips[1]}"
            else display_ips="${ips[0]}"; fi
            
            if [ ${#display_ips} -gt 26 ]; then display_ips="${display_ips:0:23}..."; fi
            
            local raw_eng="${iface_eng_arr["$iface_info"]}"
            local disp_eng=$(format_engine "$raw_eng")
            local clean_eng=$(echo -e "$disp_eng" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            local pad_eng=$(printf '%*s' "$(( 20 - ${#clean_eng} ))" "")
            
            local obfs_indicator=""
            if grep -q "\-d ${ips[0]} " "$OBFS_DIR/nat.sh" 2>/dev/null; then obfs_indicator="${M}[OBFS]${NC}"; fi
            
            local fwd_dist="${Y}${total_p} Ports${NC} ${obfs_indicator}"
            local clean_fwd=$(echo -e "$fwd_dist" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            local pad=$(printf '%*s' "$(( 26 - ${#clean_fwd} ))" "")
            
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-26s${NC} ${B}│${NC} %b%s ${B}│${NC} %b%s ${B}│${NC}\n" "$clean_name" "$t_type" "$display_ips" "$disp_eng" "$pad_eng" "$fwd_dist" "$pad"
        done
    fi
    echo -e "  ${B}╰──────────────┴──────────┴────────────────────────────┴──────────────────────┴────────────────────────────╯${NC}"
}

smart_map() {
    draw_header
    echo -e "\n  ${DIM}┌─[ STRICT FORWARDING ENGINE ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} ${DIM}(Load Balancer / Stable)${NC}"
    echo -e "  ${DIM}│${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} ${DIM}(TLS/WS Obfuscator)${NC}"
    echo -e "  ${DIM}│${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Iptables Kernel NAT${NC} ${DIM}(Raw Speed / 0% CPU)${NC}"
    echo -ne "  ${DIM}└─${NC} ${C}Select ❯❯ ${NC}"; read fwd_engine
    fwd_engine=$(echo "$fwd_engine" | tr -dc '1-3')
    
    if [ -z "$fwd_engine" ]; then echo -e "  ${R}● Invalid engine!${NC}"; sleep 1; return; fi
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
        target_ip=$(echo "$target_ip" | tr -dc '0-9.')
        if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return; fi
        selected_if="Manual"
    else
        echo -e "\n  ${B}╭────────────────── Available Interfaces ────────────────────╮${NC}"
        for i in "${!gre_ifs[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${gre_ifs[$i]}"; done
        echo -e "  ${B}├──────────────────────────────────────────────────────────────┤${NC}"
        printf "  ${B}│${NC}  ${Y}m${NC} ${C}❯${NC} ${M}%-52s${NC} ${B}│${NC}\n" "Manual IP Entry (Bypass Interfaces)"
        echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
        echo -ne "  ${C}●${NC} ${W}Select Interface (0-$(( ${#gre_ifs[@]} - 1 )) or 'm'): ${NC}"; read if_choice
        if_choice=$(echo "$if_choice" | tr -dc '0-9m')
        
        if [[ "$if_choice" == "m" ]]; then
            echo -ne "\n  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
            target_ip=$(echo "$target_ip" | tr -dc '0-9.')
            if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return; fi
            selected_if="Manual"
        elif [[ "$if_choice" =~ ^[0-9]+$ ]] && [[ -n "${gre_ifs[$if_choice]}" ]]; then 
            selected_if="${gre_ifs[$if_choice]}"
            local map_ips=($(ip -o -4 addr show "$selected_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1))
            if [ ${#map_ips[@]} -eq 0 ]; then
                echo -e "  ${R}● No active IPs found on ${selected_if}!${NC}"
                echo -ne "  ${DIM}╰─❯${NC} ${W}Enter Target Destination IP manually: ${NC}"; read target_ip
                target_ip=$(echo "$target_ip" | tr -dc '0-9.')
                if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return; fi
            else
                echo -e "\n  ${B}╭────────────────── IPs on ${selected_if} ──────────────────╮${NC}"
                for i in "${!map_ips[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${G}%-50s${NC} ${B}│${NC}\n" "$i" "${map_ips[$i]}"; done
                echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
                echo -e "  ${DIM}Tip: Enter 'a' to strictly auto-distribute ports across ALL IPs.${NC}"
                echo -ne "  ${C}●${NC} ${W}Select EXACT Index to process (0-$(( ${#map_ips[@]} - 1 ))) or 'a': ${NC}"; read ip_choice
                ip_choice=$(echo "$ip_choice" | tr -dc '0-9a')
                
                if [[ "$ip_choice" == "a" ]]; then
                    selected_ips=("${map_ips[@]}")
                    is_auto_all=true
                    echo -e "  ${G}✔ Auto-Distribute mode enabled for ${#selected_ips[@]} IPs.${NC}"
                elif [[ "$ip_choice" =~ ^[0-9]+$ ]] && [[ -n "${map_ips[$ip_choice]}" ]]; then 
                    local selected_local_ip="${map_ips[$ip_choice]}"
                    local base_ip=$(echo "$selected_local_ip" | cut -d'.' -f1-3); local last_octet=$(echo "$selected_local_ip" | cut -d'.' -f4)
                    local calc_target="${base_ip}.$((last_octet + 1))"
                    [ "$last_octet" == "1" ] && calc_target="${base_ip}.2"
                    [ "$last_octet" == "2" ] && calc_target="${base_ip}.1"
                    
                    echo -ne "\n  ${C}●${NC} ${W}Confirm Exact Target IP [${calc_target}]: ${NC}"; read custom_target
                    custom_target=$(echo "$custom_target" | tr -dc '0-9.')
                    target_ip="${custom_target:-$calc_target}"
                    if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; return; fi
                else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            fi
        else echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
    fi

    if [ "$is_auto_all" != true ] && [ -z "$target_ip" ]; then echo -e "  ${R}● Target IP cannot be empty!${NC}"; sleep 1; return; fi

    echo -ne "\n  ${C}●${NC} ${W}Enter Exact Local Ports (e.g. 80,443,1080): ${NC}"; read raw_ports
    raw_ports=$(echo "$raw_ports" | tr -dc '0-9,')
    if [ -z "$raw_ports" ]; then echo -e "  ${R}● Invalid port format!${NC}"; sleep 1.5; return; fi
    clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
    
    echo -e "\n  ${Y}● Applying Strict 1-to-1 Mappings...${NC}"
    echo -e "  ${B}╭──────────────┬─────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "Local Port" "Engine" "Target IP"
    echo -e "  ${B}├──────────────┼─────────┼────────────────────────────────────────────┤${NC}"
    
    local port_idx=0
    for p in $clean_ports; do
        if [ "$p" -gt 65535 ]; then continue; fi
        
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
        elif grep -q -- "--dport $p " "$IPT_CONF" 2>/dev/null; then skip_reason="KernelNAT"
        fi

        if [ -n "$skip_reason" ]; then
            printf "  ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "-" "Skipped (Used by $skip_reason)"
            continue
        fi
        
        if [ "$fwd_engine" == "1" ]; then
            (
                flock -x 200
                echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
            ) 200>/var/lock/mporter_haproxy.lock
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${C}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "HAProxy" "$target_ip"
        
        elif [ "$fwd_engine" == "2" ]; then
            jq --arg node "tcp://:$p/$target_ip:$p" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${M}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Gost" "$target_ip"
            
        elif [ "$fwd_engine" == "3" ]; then
            echo "iptables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$target_ip\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
            echo "iptables -t nat -A POSTROUTING -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$target_ip\" -j MASQUERADE" >> "$IPT_CONF"
            printf "  ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${Y}%-7s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "Iptable" "$target_ip"
        fi
        ((port_idx++))
    done
    echo -e "  ${B}╰──────────────┴─────────┴────────────────────────────────────────────╯${NC}"
    
    sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null

    [ "$fwd_engine" == "1" ] && systemctl restart haproxy 2>/dev/null
    [ "$fwd_engine" == "2" ] && systemctl restart gost 2>/dev/null
    [ "$fwd_engine" == "3" ] && systemctl restart mporter-iptables 2>/dev/null

    if [ "$fwd_engine" == "1" ] || [ "$fwd_engine" == "3" ]; then
        echo -ne "\n  ${C}●${NC} ${W}Enable Strict OBFS Stealth for these ports? (y/n): ${NC}"; read enable_obfs
        enable_obfs=$(echo "$enable_obfs" | tr -dc 'yn')
        
        if [[ "$enable_obfs" == "y" ]]; then
            local remote_pub=""
            if [[ "$selected_if" != "Manual" ]]; then
                if [ -f "/etc/mgre/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mgre/tunnels/${selected_if}.conf" | cut -d= -f2)
                elif [ -f "/etc/mgre/vxlan/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mgre/vxlan/${selected_if}.conf" | cut -d= -f2)
                elif [ -f "/etc/ml2tp/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/ml2tp/tunnels/${selected_if}.conf" | cut -d= -f2)
                elif [ -f "/etc/mhysteria/tunnels/${selected_if}.conf" ]; then remote_pub=$(grep "REMOTE_PUB" "/etc/mhysteria/tunnels/${selected_if}.conf" | cut -d= -f2); fi
            fi
            
            if [ -z "$remote_pub" ]; then 
                echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP: ${NC}"; read remote_pub
                remote_pub=$(echo "$remote_pub" | tr -dc '0-9.')
            else 
                echo -e "  ${G}✔ Auto-detected Kharej IP: ${remote_pub}${NC}"
            fi
            
            echo -ne "  ${C}●${NC} ${W}Enter Kharej Stealth Port (Target Receiver): ${NC}"; read stealth_port
            stealth_port=$(echo "$stealth_port" | tr -dc '0-9')
            echo -ne "  ${C}●${NC} ${W}Select Protocol [1: TLS | 2: WS | 3: WSS] (Default 1): ${NC}"; read t_proto
            t_proto=$(echo "$t_proto" | tr -dc '1-3')
            
            local method="relay+tls"; [ "$t_proto" == "2" ] && method="relay+ws"; [ "$t_proto" == "3" ] && method="relay+wss"

            mkdir -p "$OBFS_DIR"
            local port_idx=0
            for p in $clean_ports; do
                if [ "$p" -gt 65535 ]; then continue; fi
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
    fi
    echo -ne "\n  ${G}● Success! Press Enter...${NC}"; read dummy
}

edit_mapping() {
    draw_header
    echo -e "\n  ${DIM}┌─[ EDIT FORWARDING MAPPINGS ]${NC}"
    local h_map=""; local g_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1)
    
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' "$IPT_CONF" 2>/dev/null)
    
    local all_ips=$(echo -e "$h_map\n$g_map\n$ipt_map" | grep -v '^$' | sort -u)
    if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi

    local ip_arr=($all_ips)
    echo -e "  ${B}╭────────────────── Select Target IP ──────────────────────╮${NC}"
    for i in "${!ip_arr[@]}"; do printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-52s${NC} ${B}│${NC}\n" "$i" "${ip_arr[$i]}"; done
    echo -e "  ${B}╰──────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}Select Index ❯❯ ${NC}"; read ip_idx
    ip_idx=$(echo "$ip_idx" | tr -dc '0-9')

    local target_ip="${ip_arr[$ip_idx]}"
    if [ -z "$target_ip" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi

    while true; do
        draw_header
        local t_ports=""
        [ -f "$H_CONF" ] && t_ports+=$(grep "$target_ip:" "$H_CONF" 2>/dev/null | awk '{print $2}' | cut -d'_' -f2 | xargs)
        [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && t_ports+=" "$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep "$target_ip:" | grep -oP 'tcp://:\K[0-9]+' | xargs)
        
        [ -f "$IPT_CONF" ] && t_ports+=" "$(grep "MPORTER_NAT_$target_ip" "$IPT_CONF" 2>/dev/null | grep "PREROUTING" | grep -oP -- '--dport \K[0-9]+' | xargs)
        
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
        
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Migrate Target IP${NC} ${DIM}(Move ports to a new IP)${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back to Main Menu${NC}\n"
        echo -ne "  ${C}Select Action ❯❯ ${NC}"; read edit_opt
        edit_opt=$(echo "$edit_opt" | tr -dc '0-4')

        case $edit_opt in
            1) 
                echo -ne "\n  ${C}●${NC} ${W}Enter New Ports to Add (e.g. 80,443): ${NC}"; read raw_ports
                raw_ports=$(echo "$raw_ports" | tr -dc '0-9,')
                if [ -z "$raw_ports" ]; then echo -e "  ${R}● Invalid port format!${NC}"; sleep 1.5; continue; fi
                clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -u -n | xargs)
                echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}HAProxy${NC} | ${W}2${NC} ${DIM}❯${NC} ${M}Gost${NC} | ${W}3${NC} ${DIM}❯${NC} ${Y}Iptables NAT${NC}"
                echo -ne "  ${C}Select Engine ❯❯ ${NC}"; read e_opt
                e_opt=$(echo "$e_opt" | tr -dc '1-3')
                
                for p in $clean_ports; do
                    if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":$p$"; then continue; fi
                    if [ "$e_opt" == "1" ]; then
                        (
                            flock -x 200
                            echo -e "\nfrontend ft_$p\n    bind *:$p\n    default_backend bk_$p\nbackend bk_$p\n    server srv_$p $target_ip:$p check inter 5000" >> "$H_CONF"
                        ) 200>/var/lock/mporter_haproxy.lock
                    elif [ "$e_opt" == "2" ]; then 
                        jq --arg node "tcp://:$p/$target_ip:$p" '.ServeNodes += [$node]' "$G_CONF" > /tmp/gconfig.json && mv /tmp/gconfig.json "$G_CONF"
                    elif [ "$e_opt" == "3" ]; then
                        echo "iptables -t nat -A PREROUTING -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$target_ip\" -j DNAT --to-destination $target_ip:$p" >> "$IPT_CONF"
                        echo "iptables -t nat -A POSTROUTING -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_NAT_$target_ip\" -j MASQUERADE" >> "$IPT_CONF"
                    fi
                    
                    if [ "$has_obfs" = true ] && [ "$e_opt" != "2" ]; then
                        local ex_gost=$(grep "$target_ip:" "$OBFS_DIR/gost.sh" | head -n 1)
                        local remote_pub=$(echo "$ex_gost" | grep -oP '://\K[0-9\.]+'); local stealth_port=$(echo "$ex_gost" | grep -oP "$remote_pub:\K[0-9]+")
                        local method=$(echo "$ex_gost" | grep -oP -- '-F \K[a-z\+]+')
                        local obfs_lport=$((30000 + p)); [ "$obfs_lport" -gt 65535 ] && obfs_lport=$(( p + 10000 ))
                        echo "iptables -t nat -A OUTPUT -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_OBFS\" -j REDIRECT --to-ports $obfs_lport" >> "$OBFS_DIR/nat.sh"
                        echo "/usr/local/bin/gost -L tcp://:$obfs_lport/$target_ip:$p -F $method://$remote_pub:$stealth_port &" >> "$OBFS_DIR/gost.sh"
                    fi
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                [ "$e_opt" == "1" ] && systemctl restart haproxy 2>/dev/null
                [ "$e_opt" == "2" ] && systemctl restart gost 2>/dev/null
                [ "$e_opt" == "3" ] && systemctl restart mporter-iptables 2>/dev/null
                [ "$has_obfs" = true ] && build_obfs_runner
                echo -e "  ${G}● Ports added successfully!${NC}"; sleep 1.5 ;;
            2)
                echo -ne "\n  ${C}●${NC} ${W}Enter Exact Ports to Remove (e.g. 80,443): ${NC}"; read raw_ports
                raw_ports=$(echo "$raw_ports" | tr -dc '0-9,')
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
                    if [ -f "$IPT_CONF" ]; then
                        sed -i "/--dport $p .*MPORTER_NAT_$target_ip/d" "$IPT_CONF" 2>/dev/null
                    fi
                    if [ -f "$OBFS_DIR/nat.sh" ]; then 
                        sed -i "/--dport $p /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                        sed -i "/:$p -F/d" "$OBFS_DIR/gost.sh" 2>/dev/null
                    fi
                done
                sed -i '/^[[:space:]]*$/d' "$H_CONF" 2>/dev/null
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
                [ "$has_obfs" = true ] && build_obfs_runner
                echo -e "  ${G}● Ports removed securely!${NC}"; sleep 1.5 ;;
            3)
                if [ "$has_obfs" = true ]; then
                    sed -i "/-d $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    sed -i "/\/$target_ip:/d" "$OBFS_DIR/gost.sh" 2>/dev/null
                    local iface_info=$(get_iface_info "$target_ip")
                    local t_name="${iface_info##*|}"
                    sed -i "/OBFS_CNT_TX_${t_name}_${target_ip}/d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    sed -i "/OBFS_CNT_TX_${t_name}.*-d $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    sed -i "/OBFS_CNT_RX_${t_name}.*-s $target_ip /d" "$OBFS_DIR/nat.sh" 2>/dev/null
                    build_obfs_runner; echo -e "  ${G}● OBFS Disabled for $target_ip.${NC}"; sleep 1.5
                else
                    local remote_pub=""
                    shopt -s nullglob
                    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf /etc/mhysteria/tunnels/*.conf; do
                        [ -f "$conf" ] || continue
                        if grep -q "=$target_ip" "$conf" || grep -q "=$(echo "$target_ip" | cut -d. -f1-3)" "$conf"; then
                            remote_pub=$(grep "REMOTE_PUB=" "$conf" | cut -d= -f2)
                            break
                        fi
                    done
                    shopt -u nullglob
                    
                    if [ -z "$remote_pub" ]; then 
                        echo -ne "  ${C}●${NC} ${W}Enter Kharej Server PUBLIC IP: ${NC}"; read remote_pub
                        remote_pub=$(echo "$remote_pub" | tr -dc '0-9.')
                    else 
                        echo -e "  ${G}✔ Auto-detected Kharej IP: ${remote_pub}${NC}"
                    fi
                    
                    echo -ne "  ${C}●${NC} ${W}Enter Kharej Stealth Port: ${NC}"; read stealth_port
                    stealth_port=$(echo "$stealth_port" | tr -dc '0-9')
                    echo -ne "  ${C}●${NC} ${W}Select Protocol [1: TLS | 2: WS | 3: WSS] (Default 1): ${NC}"; read t_proto
                    t_proto=$(echo "$t_proto" | tr -dc '1-3')
                    
                    local method="relay+tls"; [ "$t_proto" == "2" ] && method="relay+ws"; [ "$t_proto" == "3" ] && method="relay+wss"

                    mkdir -p "$OBFS_DIR"

                    for p in $t_ports; do
                        if command -v jq >/dev/null 2>&1 && jq -e ".ServeNodes[] | select(. | contains(\"tcp://:$p/\"))" "$G_CONF" >/dev/null 2>&1; then continue; fi
                        
                        local obfs_lport=$((30000 + p)); [ "$obfs_lport" -gt 65535 ] && obfs_lport=$(( p + 10000 ))
                        echo "iptables -t nat -A OUTPUT -d $target_ip -p tcp --dport $p -m comment --comment \"MPORTER_OBFS\" -j REDIRECT --to-ports $obfs_lport" >> "$OBFS_DIR/nat.sh"
                        echo "/usr/local/bin/gost -L tcp://:$obfs_lport/$target_ip:$p -F $method://$remote_pub:$stealth_port &" >> "$OBFS_DIR/gost.sh"
                    done
                    
                    local iface_info=$(get_iface_info "$target_ip")
                    local t_name="${iface_info##*|}"
                    if ! grep -q "OBFS_CNT_TX_${t_name}_${target_ip}" "$OBFS_DIR/nat.sh" 2>/dev/null; then
                        echo "iptables -t mangle -A OUTPUT -d $target_ip -m comment --comment \"OBFS_CNT_TX_${t_name}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                        echo "iptables -t mangle -A INPUT -s $target_ip -m comment --comment \"OBFS_CNT_RX_${t_name}\" 2>/dev/null" >> "$OBFS_DIR/nat.sh"
                        echo "# OBFS_CNT_TX_${t_name}_${target_ip}" >> "$OBFS_DIR/nat.sh"
                    fi
                    build_obfs_runner; echo -e "  ${G}● OBFS Enabled for $target_ip.${NC}"; sleep 1.5
                fi ;;
            4)
                echo -ne "\n  ${C}●${NC} ${W}Enter New Destination IP: ${NC}"; read new_ip
                new_ip=$(echo "$new_ip" | tr -dc '0-9.')
                if [[ ! "$new_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo -e "  ${R}● Invalid IP format!${NC}"; sleep 1.5; continue; fi
                echo -e "  ${DIM}● Migrating $target_ip -> $new_ip ...${NC}"
                
                if [ -f "$H_CONF" ]; then sed -i "s/ $target_ip:/ $new_ip:/g" "$H_CONF"; fi
                if [ -f "$IPT_CONF" ]; then sed -i "s/$target_ip/$new_ip/g" "$IPT_CONF"; fi
                
                if [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1; then
                    jq --arg old "/$target_ip:" --arg new "/$new_ip:" '.ServeNodes = [.ServeNodes[]? | sub($old; $new)]' "$G_CONF" > /tmp/g.json && mv /tmp/g.json "$G_CONF"
                fi
                
                if [ -f "$OBFS_DIR/nat.sh" ]; then sed -i "s/\b${target_ip}\b/${new_ip}/g" "$OBFS_DIR/nat.sh"; fi
                if [ -f "$OBFS_DIR/gost.sh" ]; then sed -i "s/\b${target_ip}\b/${new_ip}/g" "$OBFS_DIR/gost.sh"; fi
                
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
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
    echo -e "  ${B}├──────────────┬──────────┬────────────────┬──────────────────────────┬────────────────────────────────────┤${NC}"
    printf "  ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-14s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${W}%-34s${NC} ${B}│${NC}\n" "TUNNEL NAME" "TYPE" "TARGET IP" "FORWARD ENGINE" "FORWARDED PORTS"
    echo -e "  ${B}├──────────────┼──────────┼────────────────┼──────────────────────────┼────────────────────────────────────┤${NC}"
    
    local h_map=""; local g_map=""; local ipt_map=""; local ext_map_raw=""
    
    [ -f "$H_CONF" ] && h_map=$(grep -E "frontend ft_|server srv_" "$H_CONF" 2>/dev/null | awk '/frontend ft_/ {port=$2; sub(/ft_/, "", port)} /server srv_/ {ip=$3; sub(/:.*/, "", ip); print port "|" ip "|HAP"}')
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | sed -E 's/tcp:\/\/:([0-9]+)\/([0-9\.]+):.*/\1|\2|GST/g')
    [ -f "$IPT_CONF" ] && ipt_map=$(grep "PREROUTING" "$IPT_CONF" 2>/dev/null | grep -oP -- '--dport \K[0-9]+.*MPORTER_NAT_[0-9\.]+' | awk '{print $1 "|" $NF "|IPT"}' | sed 's/MPORTER_NAT_//g')
    
    shopt -s nullglob
    for conf in /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf; do
        [ -f "$conf" ] || continue
        local TYPE="" FWD_TCP="" FWD_UDP="" CORE_SUBNET="" TUN_ID="" VNI_ID=""
        source "$conf" 2>/dev/null
        [ "$TYPE" != "1" ] && continue
        local t_ip=""
        if [ -n "$TUN_ID" ]; then t_ip="${CORE_SUBNET:-10.76.${TUN_ID}}.2"
        elif [ -n "$VNI_ID" ]; then t_ip="${CORE_SUBNET:-10.88.${VNI_ID}}.2"; fi
        for p in $(echo "$FWD_TCP,$FWD_UDP" | tr ',' ' ' | xargs -n1 2>/dev/null | sort -u); do
            if [ -n "$p" ]; then ext_map_raw+="$p|$t_ip|TUN\n"; fi
        done
    done
    shopt -u nullglob
    
    local mappings=$(echo -e "$h_map\n$g_map\n$ipt_map\n$ext_map_raw" | grep -v '^$')
    
    if [ -z "$mappings" ]; then 
        printf "  ${B}│${NC} ${DIM}%-104s${NC} ${B}│${NC}\n" "  No active mappings. Ready to route strictly."
    else
        declare -A ip_ports_arr; declare -A ip_eng_arr
        while IFS='|' read -r p_num d_ip eng; do 
            if [ -n "$d_ip" ]; then 
                ip_ports_arr["$d_ip"]+="$p_num, "
                if [[ ! "${ip_eng_arr["$d_ip"]}" == *"$eng"* ]]; then
                    ip_eng_arr["$d_ip"]+="$eng/"
                fi
            fi
        done <<< "$mappings"

        for d_ip in $(for i in "${!ip_ports_arr[@]}"; do echo "$i"; done | sort); do
            local iface_info=$(get_iface_info "$d_ip")
            local t_type="${iface_info%%|*}"
            local t_name="${iface_info##*|}"
            
            local clean_name="${t_name}"
            [ ${#clean_name} -gt 12 ] && clean_name="${clean_name:0:9}..."

            local raw_eng="${ip_eng_arr[$d_ip]}"
            local disp_eng=$(format_engine "$raw_eng")
            local clean_eng=$(echo -e "$disp_eng" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            local pad_eng=$(printf '%*s' "$(( 24 - ${#clean_eng} ))" "")

            local raw_ports="${ip_ports_arr[$d_ip]}"; raw_ports="${raw_ports%, }"
            local display_ports=""
            for p in $(echo "$raw_ports" | tr ',' ' ' | sort -u -n); do
                if grep -q "dport $p " "$OBFS_DIR/nat.sh" 2>/dev/null; then display_ports+="${M}${p}*(OBFS)${Y}, "
                else display_ports+="${p}, "; fi
            done
            display_ports="${display_ports%, }"
            
            local clean_str=$(echo -e "$display_ports" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g")
            if [ ${#clean_str} -gt 34 ]; then display_ports="${clean_str:0:31}..."; clean_str="$display_ports"; fi
            local pad=$(printf '%*s' "$((34 - ${#clean_str}))" "")
            
            printf "  ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} ${M}%-8s${NC} ${B}│${NC} ${G}%-14s${NC} ${B}│${NC} %b%s ${B}│${NC} ${Y}%b%s ${B}│${NC}\n" "$clean_name" "$t_type" "$d_ip" "$disp_eng" "$pad_eng" "$display_ports" "$pad"
        done
    fi
    echo -e "  ${B}╰──────────────┴──────────┴───────────────┴──────────────────┴─────────────────────────────────────╯${NC}"
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
    p_opt=$(echo "$p_opt" | tr -dc '0-3')
    
    local h_map=""; local g_map=""; local ipt_map=""
    [ -f "$H_CONF" ] && h_map=$(grep -oP 'server srv_[0-9_]+ \K[0-9\.]+|server srv_[0-9]+ \K[0-9\.]+' "$H_CONF" 2>/dev/null)
    [ -f "$G_CONF" ] && command -v jq >/dev/null 2>&1 && g_map=$(jq -r '.ServeNodes[]?' "$G_CONF" 2>/dev/null | grep -oP '\/\K[0-9\.,:]+' | tr ',' '\n' | cut -d: -f1)
    [ -f "$IPT_CONF" ] && ipt_map=$(grep -oP -- 'MPORTER_NAT_\K[0-9\.]+' "$IPT_CONF" 2>/dev/null | sort -u)
    
    local all_ips=$(echo -e "$h_map\n$g_map\n$ipt_map" | grep -v '^$' | sort -u)

    case $p_opt in
        1)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            declare -A iface_ips
            for ip in $all_ips; do
                local iface_info=$(get_iface_info "$ip")
                iface_ips["$iface_info"]+="$ip "
            done
            
            local i=0; local iface_list=()
            echo -e "\n  ${B}╭────────────────── Select Interface to Purge ─────────────────╮${NC}"
            for ifc_info in $(for key in "${!iface_ips[@]}"; do echo "$key"; done | sort); do
                iface_list[$i]="$ifc_info"
                local ip_arr=(${iface_ips[$ifc_info]})
                local t_type="${ifc_info%%|*}"
                local t_name="${ifc_info##*|}"
                local disp_name="${t_name} [${t_type}]"
                
                local raw_str=$(printf "  %02d ❯ %-22s (Contains %-2d IPs)" "$i" "$disp_name" "${#ip_arr[@]}")
                local pad=$(( 58 - ${#raw_str} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
                
                printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-22s${NC} ${DIM}(Contains %-2d IPs)${NC}%s${B}│${NC}\n" "$i" "$disp_name" "${#ip_arr[@]}" "$sp"
                ((i++))
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx
            idx=$(echo "$idx" | tr -dc '0-9')
            
            local selected_ifc_info="${iface_list[$idx]}"
            if [ -z "$selected_ifc_info" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            
            local t_name="${selected_ifc_info##*|}"
            echo -ne "  ${Y}● Deep Purge ALL IPs on $t_name? (y/n): ${NC}"; read conf
            conf=$(echo "$conf" | tr -dc 'yn')
            if [[ "$conf" == "y" ]]; then
                for ip in ${iface_ips[$selected_ifc_info]}; do purge_ip_core "$ip"; done
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
                [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
                echo -e "  ${G}● Interface $t_name purged successfully!${NC}"; sleep 1.5
            fi ;;
        2)
            if [ -z "$all_ips" ]; then echo -e "  ${R}● No active mappings found!${NC}"; sleep 2; return; fi
            local ip_arr=($all_ips)
            echo -e "\n  ${B}╭────────────────── Select Target IP to Purge ─────────────────╮${NC}"
            for i in "${!ip_arr[@]}"; do 
                local ifc_info=$(get_iface_info "${ip_arr[$i]}")
                local t_type="${ifc_info%%|*}"
                local t_name="${ifc_info##*|}"
                local disp_name="${t_name} [${t_type}]"
                
                local raw_str=$(printf "  %02d ❯ %-15s (%s)" "$i" "${ip_arr[$i]}" "$disp_name")
                local pad=$(( 58 - ${#raw_str} )); [ "$pad" -lt 0 ] && pad=0; local sp=$(printf '%*s' "$pad" "")
                
                printf "  ${B}│${NC}  ${Y}%02d${NC} ${C}❯${NC} ${W}%-15s${NC} ${DIM}(%s)${NC}%s${B}│${NC}\n" "$i" "${ip_arr[$i]}" "$disp_name" "$sp"
            done
            echo -e "  ${B}╰──────────────────────────────────────────────────────────────╯${NC}"
            echo -ne "  ${C}Select Index ❯❯ ${NC}"; read idx
            idx=$(echo "$idx" | tr -dc '0-9')
            
            local target_ip="${ip_arr[$idx]}"
            if [ -z "$target_ip" ]; then echo -e "  ${R}● Invalid selection!${NC}"; sleep 1; return; fi
            
            purge_ip_core "$target_ip"
            systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
            [ -x "/usr/local/bin/mporter-obfs.sh" ] && /usr/local/bin/mporter-obfs.sh
            echo -e "  ${G}● IP $target_ip purged successfully!${NC}"; sleep 1.5 ;;
        3) 
            echo -ne "  ${R}● Wipe all active mappings globally? (y/n) ❯❯ ${NC}"; read confirm
            confirm=$(echo "$confirm" | tr -dc 'yn')
            if [[ "$confirm" == "y" ]]; then
                echo -e "global\n    maxconn 500000\n    daemon\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n" > "$H_CONF"
                echo -e "frontend dummy_check\n    bind 127.0.0.1:9999\n    default_backend dummy_back\nbackend dummy_back\n    server local 127.0.0.1:9999" >> "$H_CONF"
                echo '{"Debug": false, "ServeNodes": []}' > "$G_CONF"
                > "$IPT_CONF"
                rm -rf "$OBFS_DIR"
                systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null
                build_obfs_runner
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
    wd_opt=$(echo "$wd_opt" | tr -dc '0-2')
    
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
    echo -e "\n  ${DIM}┌─[ RESTART SERVICES ]${NC}\n  ${DIM}│${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Restart HAProxy Engine${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}Restart Gost Engine${NC}\n  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Restart Kernel NAT Engine${NC}\n  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Restart ALL Engines${NC}\n  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read r_opt
    r_opt=$(echo "$r_opt" | tr -dc '0-4')
    echo ""
    case $r_opt in
        1) systemctl restart haproxy 2>/dev/null; echo -e "  ${G}● HAProxy restarted successfully.${NC}" ;;
        2) systemctl restart gost 2>/dev/null; echo -e "  ${G}● Gost restarted successfully.${NC}" ;;
        3) systemctl restart mporter-iptables 2>/dev/null; echo -e "  ${G}● Kernel NAT restarted successfully.${NC}" ;;
        4) systemctl restart haproxy 2>/dev/null; systemctl restart gost 2>/dev/null; systemctl restart mporter-iptables 2>/dev/null; echo -e "  ${G}● All engines restarted successfully.${NC}" ;;
        0) return ;; *) echo -e "  ${R}● Invalid selection!${NC}" ;;
    esac
    sleep 1.5
}

while true; do
    badge=""
    if [ -f "$SECURE_TMP/.mporter_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.mporter_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available ➔ v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ DEPLOYMENT & DESTRUCTION ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Install & Configure Tri-Core System${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Uninstall Engines & Purge (Nuclear Wipe)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}Add Port Mappings (Strict 1-to-1)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${Y}Edit Mappings (Add/Del/OBFS)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${Y}Delete & Purge Mappings (By Interface/IP/All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & DETAILS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${M}View IP -> Port Matrix${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Smart Interface Watchdog (Auto-Cleanup)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Manual Restart Services${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${G}Instant OTA Update (Script Only)${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Exit Workspace${NC}\n"

    echo -ne "  ${C}MPorter ❯❯ ${NC}"; read -t 30 opt
    opt=$(echo "$opt" | tr -dc '0-9')
    case $opt in
        1) install_core_engines ;;
        2) echo -ne "  ${R}● Nuclear Wipe? (y/n) ❯❯ ${NC}"; read confirm
           confirm=$(echo "$confirm" | tr -dc 'yn')
           if [[ "$confirm" == "y" ]]; then 
               systemctl stop haproxy 2>/dev/null; systemctl disable haproxy 2>/dev/null
               systemctl stop gost 2>/dev/null; systemctl disable gost 2>/dev/null
               systemctl stop mporter-obfs 2>/dev/null; systemctl disable mporter-obfs 2>/dev/null
               systemctl stop mporter-iptables 2>/dev/null; systemctl disable mporter-iptables 2>/dev/null
               systemctl stop mporter-watchdog 2>/dev/null; systemctl disable mporter-watchdog 2>/dev/null
               rm -rf /etc/haproxy /var/lib/haproxy /usr/local/bin/gost /etc/gost /etc/systemd/system/gost.service "$OBFS_DIR" "$IPT_DIR" /etc/systemd/system/mporter-obfs.service /etc/systemd/system/mporter-iptables.service /etc/systemd/system/mporter-watchdog.service
               apt-get purge -y haproxy 2>/dev/null; systemctl daemon-reload
               iptables -t nat -S OUTPUT 2>/dev/null | grep "MPORTER_OBFS" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
               iptables -t mangle -S OUTPUT 2>/dev/null | grep "OBFS_CNT_TX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               iptables -t mangle -S INPUT 2>/dev/null | grep "OBFS_CNT_RX_" | sed 's/-A /-D /' | while read rule; do iptables -t mangle $rule; done
               iptables -t nat -S PREROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
               iptables -t nat -S POSTROUTING 2>/dev/null | grep "MPORTER_NAT_" | sed 's/-A /-D /' | while read rule; do iptables -t nat $rule; done
               echo -e "  ${G}● Erased from system completely.${NC}"; sleep 1; exit 0
           fi ;;
        3) smart_map ;; 
        4) edit_mapping ;; 
        5) purge_menu ;;
        6) show_table ;;
        7) smart_watchdog_menu ;; 
        8) manual_restart ;; 
        9) self_update_module ;;
        0) clear; exit 0 ;;
    esac
done
