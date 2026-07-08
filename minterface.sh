#!/bin/bash
# --- MDesign Modular Core (minterface.sh) | Interface Mapper v1.0 ---

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
    local str1=" MDesign Interface Matrix 1.0 "
    local str2=" IP: $s_ip "
    local str3=" ROLE: $role "
    
    # حذف کدهای رنگی برای محاسبه طول دقیق کاراکترهای هدر
    local raw_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access Node)" || echo "KHAREJ (Gateway Node)")
    [ ${#configs[@]} -eq 0 ] && raw_role="Unknown (No Tunnels)"
    
    local raw_len=$(( ${#str1} + 1 + ${#str2} + 1 + 7 + ${#raw_role} ))
    local pad_len=$(( 96 - raw_len ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")
    
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${B}│${NC}${DIM} ROLE:${NC} ${role}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
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

        # چک کردن وضعیت لایو اینترفیس در سیستم‌عامل
        local oper_state="${R}● DOWN${NC}"
        if ip link show "$T_NAME" >/dev/null 2>&1; then
            [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" != "down" ] && oper_state="${G}● UP${NC}"
        fi

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        printf "  ${B}│${NC} %b▼ Interface: %-60s%b %b%-22s%b ${B}│${NC}\n" "${title_color}" "$T_NAME" "${NC}" "${DIM}" "State: $oper_state" "${NC}"
        echo -e "  ${B}├──────────────────────────────┬─────────────────────────────────────────────────────────────────┤${NC}"
        
        # ردیف پروتکل و لینک عمومی
        printf "  ${B}│${NC} %-28s ${B}│${NC} ${W}%-63s${NC} ${B}│${NC}\n" "Tunnel Infrastructure" "$proto_lbl Engine"
        printf "  ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC} ${DIM}Local:${NC} %-24s ${DIM}Remote:${NC} %-23s ${B}│${NC}\n" "Public Endpoint IPs" "$LOCAL_PUB" "$REMOTE_PUB"
        echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
        
        # ردیف هسته IPv4
        printf "  ${B}│${NC} %-28s ${B}│${NC} ${G}Local Core IP:${NC} %-21s ${Y}Remote Core IP:${NC} %-19s ${B}│${NC}\n" "Core IPv4 Network" "$lip" "$tip"
        
        # ردیف ورژن ۶ (فقط در صورت وجود پروتکل 6to4)
        if [[ "$TUN_PROTO" == "6to4" ]]; then
            echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
            printf "  ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC} ${DIM}Local IPv6 :${NC} %-50s ${B}│${NC}\n" "Native IPv6 Allocation" "$LOCAL_IP6"
            printf "  ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC} ${DIM}Remote IPv6:${NC} %-50s ${B}│${NC}\n" "" "$REMOTE_IP6"
        fi
        
        echo -e "  ${B}╰──────────────────────────────┴─────────────────────────────────────────────────────────────────╯${NC}\n"
    done
    
    echo -ne "  ${DIM}Press Enter to return to Dashboard...${NC}"; read
}

while true; do
    draw_header
    render_matrix
    break
done
