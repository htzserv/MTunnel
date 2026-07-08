cat << 'EOF' > /usr/bin/minterface
#!/bin/bash
# --- MDesign Modular Core (minterface.sh) | Interface Mapper v1.2.0 (Live Connectivity) ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

detect_server_role() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "${DIM}Unknown (No Tunnels)${NC}"
        return
    fi
    source "${configs[0]}"
    if [ "$TYPE" == "1" ]; then
        echo -e "${G}IRAN (Access Node)${NC}"
    else
        echo -e "${M}KHAREJ (Gateway Node)${NC}"
    fi
}

draw_header() {
    local s_ip=$(get_local_ip)
    local role=$(detect_server_role)
    clear; echo ""
    local str1=" MDesign Interface Matrix 1.2 "
    local str2=" IP: $s_ip "
    
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    local raw_role="Unknown (No Tunnels)"
    if [ ${#configs[@]} -gt 0 ]; then
        source "${configs[0]}"
        raw_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access Node)" || echo "KHAREJ (Gateway Node)")
    fi
    local str3=" ROLE: $raw_role "
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + ${#str3} ))
    local pad_len=$(( 96 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ROLE:${NC} ${role}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

print_row_2col() {
    local l_raw="$1"; local l_col="$2"; local r_raw="$3"; local r_col="$4"
    local l_pad=$(( 28 - ${#l_raw} ))
    [ "$l_pad" -lt 0 ] && l_pad=0
    local l_spaces=$(printf '%*s' "$l_pad" "")
    local r_pad=$(( 63 - ${#r_raw} ))
    [ "$r_pad" -lt 0 ] && r_pad=0
    local r_spaces=$(printf '%*s' "$r_pad" "")
    echo -e "  ${B}│${NC} ${l_col}${l_spaces} ${B}│${NC} ${r_col}${r_spaces} ${B}│${NC}"
}

render_matrix() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then
        echo -e "\n  ${R}● No active network interfaces configured via MGRE Core.${NC}"; sleep 2; return
    fi

    echo -e "\n  ${Y}● Active Network Interface Blueprint:${NC}"
    
    for conf in "${configs[@]}"; do
        source "$conf"
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        local proto_lbl="IPv4 GRE"
        local title_color="${C}"
        if [[ "$TUN_PROTO" == "6to4" ]]; then 
            proto_lbl="6to4 IP6GRE"
            title_color="${M}"
        fi

        # 1. وضعیت کارت شبکه (Local OS State)
        local stat_raw="● DOWN"; local stat_color="${R}"; local sys_uptime="Offline"
        if ip link show "$T_NAME" >/dev/null 2>&1; then
            if [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ]; then
                stat_raw="● UP"; stat_color="${G}"
                local created=$(stat -c %Y "/sys/class/net/$T_NAME" 2>/dev/null)
                if [ -n "$created" ] && [ "$created" -gt 0 ]; then
                    local now=$(date +%s); local diff=$((now - created))
                    local days=$((diff / 86400)); local hours=$(( (diff % 86400) / 3600 )); local mins=$(( (diff % 3600) / 60 ))
                    sys_uptime=""
                    [ "$days" -gt 0 ] && sys_uptime="${days}d "
                    [ "$hours" -gt 0 ] && sys_uptime="${sys_uptime}${hours}h "
                    sys_uptime="${sys_uptime}${mins}m"
                fi
            fi
        fi

        # 2. تست ارتباط زنده با سرور مقصد (Live Connection Check)
        local link_raw="○ OFFLINE"
        local link_color="${R}"
        if ping -c 1 -W 1 "$tip" >/dev/null 2>&1; then
            link_raw="● ONLINE"
            link_color="${G}"
        fi

        # استخراج پورت‌های فوروارد شده برای این تانل
        local h_ports=""; local g_ports=""
        local subnets=("$c_sub")
        for v_lip in $(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1); do
            subnets+=("$(echo "$v_lip" | cut -d'.' -f1-3)")
        done
        
        if [ -f "/etc/haproxy/haproxy.cfg" ]; then
            local h_tmp=""
            for sub in "${subnets[@]}"; do
                local p=$(grep "server srv_" /etc/haproxy/haproxy.cfg | grep "${sub}\." | awk '{print $2}' | cut -d'_' -f2)
                [ -n "$p" ] && h_tmp="$h_tmp\n$p"
            done
            [ -n "$h_tmp" ] && h_ports=$(echo -e "$h_tmp" | grep -v '^$' | sort -un | paste -sd "," -)
        fi
        
        if [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1; then
            local g_tmp=""
            for sub in "${subnets[@]}"; do
                local p=$(jq -r '.ServeNodes[]' /etc/gost/config.json 2>/dev/null | grep "${sub}\." | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/')
                [ -n "$p" ] && g_tmp="$g_tmp\n$p"
            done
            [ -n "$g_tmp" ] && g_ports=$(echo -e "$g_tmp" | grep -v '^$' | sort -un | paste -sd "," -)
        fi
        
        [ -z "$h_ports" ] && h_ports="None"
        [ -z "$g_ports" ] && g_ports="None"
        [ ${#h_ports} -gt 25 ] && h_ports="${h_ports:0:22}..."
        [ ${#g_ports} -gt 25 ] && g_ports="${g_ports:0:22}..."

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        
        # محاسبه دقیق طول برای تراز کردن وضعیت، کانکشن زنده و آپتایم
        local left_part="▼ Interface: $T_NAME"
        local right_part="State: $stat_raw   Link: $link_raw   Uptime: $sys_uptime"
        local gap=$(( 94 - ${#left_part} - ${#right_part} ))
        [ "$gap" -lt 0 ] && gap=0
        local spaces=$(printf '%*s' "$gap" "")
        
        echo -e "  ${B}│${NC} ${title_color}▼ Interface: ${W}$T_NAME${NC}${spaces}${DIM}State: ${stat_color}${stat_raw}${NC}   ${DIM}Link: ${link_color}${link_raw}${NC}   ${DIM}Uptime: ${W}${sys_uptime}${NC} ${B}│${NC}"
        echo -e "  ${B}├──────────────────────────────┬─────────────────────────────────────────────────────────────────┤${NC}"
        
        print_row_2col "Tunnel Infrastructure" "${C}Tunnel Infrastructure${NC}" "$proto_lbl Engine" "${W}$proto_lbl Engine${NC}"
        print_row_2col "Public Endpoint IPs" "${DIM}Public Endpoint IPs${NC}" "Local: $LOCAL_PUB   Remote: $REMOTE_PUB" "${DIM}Local:${NC} ${W}$LOCAL_PUB${NC}   ${DIM}Remote:${NC} ${W}$REMOTE_PUB${NC}"
        
        echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
        
        print_row_2col "Core IPv4 Network" "${DIM}Core IPv4 Network${NC}" "Local: $lip   Remote: $tip" "${DIM}Local:${NC} ${G}$lip${NC}   ${DIM}Remote:${NC} ${Y}$tip${NC}"
        print_row_2col "Active Port Mappings" "${Y}Active Port Mappings${NC}" "HAProxy: $h_ports   Gost: $g_ports" "${C}HAProxy:${NC} ${W}$h_ports${NC}   ${M}Gost:${NC} ${W}$g_ports${NC}"
        
        if [[ "$TUN_PROTO" == "6to4" ]]; then
            echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
            print_row_2col "Native IPv6 Allocation" "${DIM}Native IPv6 Allocation${NC}" "Local IPv6 : $LOCAL_IP6" "${DIM}Local IPv6 :${NC} $LOCAL_IP6"
            print_row_2col "" "" "Remote IPv6: $REMOTE_IP6" "${DIM}Remote IPv6:${NC} $REMOTE_IP6"
        fi
        
        echo -e "  ${B}╰──────────────────────────────┴─────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    
    echo -ne "  ${DIM}Press Enter to return to Dashboard...${NC}"; read
}

while true; do draw_header; render_matrix; break; done
EOF
chmod +x /usr/bin/minterface
