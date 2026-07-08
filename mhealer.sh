#!/bin/bash
# --- MDesign Modular Core (mhealer.sh) | Autonomous Tunnel Healer v1.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
CONF_DIR="/etc/mgre/tunnels"

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" MDesign Autonomous Healer 1.0 "
    local str2=" IP: $s_ip "
    local padding=$(printf '%*s' "$(( 92 - ${#str1} - 1 - ${#str2} ))" "")
    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC}${W} ${s_ip} ${NC}${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

diagnose_and_heal() {
    local configs=($(ls "$CONF_DIR"/*.conf 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No configured tunnels found for healing.${NC}"; sleep 1.5; return; fi
    
    echo -e "\n  ${B}╭────────────────── Select Broken Tunnel to Heal ──────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%d${NC} ${C}❯${NC} ${W}%-55s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .conf)"
    done
    echo -e "  ${B}├──────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${B}│${NC}  ${R}0${NC} ${C}❯${NC} ${DIM}Cancel and Return${NC}                                              ${B}│${NC}"
    echo -e "  ${B}╰──────────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}MHealer ❯❯ ${NC}"; read t_idx
    [[ "$t_idx" == "0" || -z "$t_idx" ]] && return
    
    local sel_conf="${configs[$t_idx]}"
    if [ -f "$sel_conf" ]; then
        source "$sel_conf"
        echo -e "\n  ${Y}● Running Diagnostic Matrix for [${W}${T_NAME}${Y}]...${NC}"
        sleep 1
        
        # ۱. بررسی لایه فیزیکی کارت شبکه در کرنل
        echo -ne "  ${DIM}├─ Checking Kernel Interface Status... ${NC}"
        if ! ip link show "$T_NAME" >/dev/null 2>&1; then
            echo -e "${R}[CRITICAL: Missing Interface]${NC}"
            echo -e "  ${Y}🔧 Auto-Healing: Re-generating network mapping...${NC}"
            /usr/bin/mgre --apply >/dev/null 2>&1
        elif [ "$(cat /sys/class/net/$T_NAME/operstate 2>/dev/null)" == "down" ]; then
            echo -e "${R}[ERROR: Interface DOWN]${NC}"
            echo -e "  ${Y}🔧 Auto-Healing: Forcing interface UP state...${NC}"
            ip link set "$T_NAME" up
        else echo -e "${G}[OK]${NC}"; fi
        
        # ۲. بررسی تغییر احتمالی آی‌پی پابلیک لوکال (Dynamic IP Change)
        echo -ne "  ${DIM}├─ Verifying Public IP Synchronicity... ${NC}"
        local actual_ip=$(curl -s --connect-timeout 4 icanhazip.com | tr -d '[:space:]')
        if [ -n "$actual_ip" ] && [ "$actual_ip" != "$LOCAL_PUB" ]; then
            echo -e "${R}[MISMATCH DETECTED]${NC}"
            echo -e "  ${Y}🔧 Auto-Healing: Updating config from ${R}$LOCAL_PUB${Y} to ${G}$actual_ip${Y}...${NC}"
            sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$actual_ip/" "$sel_conf"
            /usr/bin/mgre --apply >/dev/null 2>&1
        else echo -e "${G}[OK]${NC}"; fi

        # ۳. بررسی و بازسازی فایروال و MSS Clamping
        echo -ne "  ${DIM}├─ Auditing Routing & Firewall Rules... ${NC}"
        local mtu_val=$([ "$TYPE" == "1" ] && echo "1436" || echo "1476")
        if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss $((mtu_val - 40)) >/dev/null 2>&1; then
            echo -e "${Y}[WARNING: Missing Clamping]${NC}"
            echo -e "  ${Y}🔧 Auto-Healing: Injecting optimal TCPMSS limits...${NC}"
            iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -j TCPMSS --set-mss $((mtu_val - 40))
        else echo -e "${G}[OK]${NC}"; fi
        
        # ۴. تست نهایی پینگ لینک
        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        echo -ne "  ${DIM}└─ Triggering Link Echo Test... ${NC}"
        if ping -c 2 -W 1 "$tip" >/dev/null 2>&1; then
            echo -e "${G}[SUCCESS: Tunnel Online and Fully Healed]${NC}"
        else
            echo -e "${R}[FAIL: Remote Endpoint is still Unreachable]${NC}"
            echo -e "  ${Y}💡 Hint: Run MHealer on the OTHER server to fix remote pipeline issues.${NC}"
        fi
        echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read
    fi
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ AUTO-HEAL OPERATIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run Manual Tunnel Diagnostic & Repair Engine${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}MHealer ❯❯ ${NC}"; read opt
    case $opt in
        1) diagnose_and_heal ;;
        0) exit 0 ;;
    esac
done
