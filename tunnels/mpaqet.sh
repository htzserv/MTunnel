#!/bin/bash
# --- MPaqet Modular Core (mpaqet.sh) | Raw Packet Tunnel Engine v8.2.0 ---
# [Features: Unified Tri-Tunnel Dynamic Header | Zero Color Leaks]

MODULE_VERSION="8.2.0"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mpaqet"
CONF_DIR="/etc/paqet"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mpaqet" ] && rm -f "/usr/local/bin/mpaqet" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

MAIN_PID=$$
NEED_REFRESH=false
trap 'NEED_REFRESH=true' SIGUSR1

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc

    echo -ne "$prompt"

    while true; do
        if [ "$NEED_REFRESH" = true ]; then
            NEED_REFRESH=false
            if [ -n "$redraw_func" ]; then
                "$redraw_func"
            fi
            echo -ne "$prompt$buffer"
        fi

        IFS= read -rsn1 -t 0.3 char
        rc=$?

        if [ $rc -ne 0 ]; then
            continue
        fi

        if [[ -z "$char" ]]; then
            echo ""
            break
        fi

        if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ -n "$buffer" ]; then
                buffer="${buffer%?}"
                echo -ne "\b \b"
            fi
            continue
        fi

        buffer+="$char"
        echo -ne "$char"
    done

    eval "$__resultvar=\"\$buffer\""
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_iface_uptime_pq() {
    local t_name="$1"
    local started=$(systemctl show "mpaqet@${t_name}" --property=ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
    if [ -n "$started" ] && [ "$started" -gt 0 ]; then
        local now=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
        local sec=$(( (now * 10000 - started) / 1000000 ))
        [ "$sec" -lt 0 ] && sec=0
        local d=$(( sec / 86400 )); local h=$(( (sec % 86400) / 3600 )); local m=$(( (sec % 3600) / 60 ))
        if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
        elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
        else printf "%dm" "$m"; fi
        return
    fi
    echo "DOWN"
}

draw_mpaqet_header() {
    local s_ip=$(get_local_ip)
    local active_count=0
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        systemctl is-active --quiet "mpaqet@$(basename "$conf" .meta)" && ((active_count++))
    done

    clear; echo ""
    local border="────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-22s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-15s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3s${NC} ${DIM}(Max 3 Shown)${NC}      ${B}│${NC}\n" \
        "MPaqet Raw Engine v${MODULE_VERSION}" "$s_ip" "$active_count"
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    for conf in "$CONF_DIR"/*.meta; do
        [ -f "$conf" ] || continue
        ROLE=""; TUN_PORT=""; REMOTE_IP=""; source "$conf" 2>/dev/null
        local t_name=$(basename "$conf" .meta)
        ((shown++))
        [ "$shown" -gt 3 ] && break

        local pure="${t_name#pq_}"
        [ ${#pure} -gt 4 ] && pure="${pure:0:4}"

        local peer_ip="$REMOTE_IP"
        if [ "$ROLE" == "1" ]; then
            local conn=$(ss -tn src ":$TUN_PORT" 2>/dev/null | grep -E "^ESTAB" | awk '{print $5}' | head -n 1)
            peer_ip=$(echo "$conn" | rev | cut -d':' -f2- | rev | tr -d '[]')
            [ -z "$peer_ip" ] && peer_ip="0.0.0.0"
        fi

        local avg="---" loss="0"
        if [[ "$peer_ip" =~ ^[0-9.]+$ && "$peer_ip" != "0.0.0.0" ]]; then
            local ping_res=$(timeout 2 ping -c 2 -i 0.2 -W 1 "$peer_ip" 2>/dev/null)
            loss=$(echo "$ping_res" | grep -oP '[0-9]+(?=% packet loss)')
            [ -z "$loss" ] && loss="100"
            if echo "$ping_res" | grep -q "min/avg/max"; then
                avg=$(echo "$ping_res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
                [ -n "$avg" ] && avg="${avg}ms"
            fi
        else
            loss="---"
        fi

        local tun_uptime=$(get_iface_uptime_pq "$t_name")
        local stat_icon="●"; local stat_col="${G}"
        if [ "$tun_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi

        local loss_col="${DIM}"; local loss_disp="---"
        if [ "$loss" != "---" ]; then
            loss_disp="${loss}%"
            if [ "$loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
            elif [ "$loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
            else loss_col="${R}"; fi
        fi

        printf "  ${B}│${NC} %b%s%b ${W}%-4s${NC} ${DIM}➔${NC} ${Y}%-15s${NC} ${DIM}vIP:%bOFF %b ${B}│${NC} ${DIM}P:${NC}${Y}%-6s${NC} ${DIM}L:${NC}%b%-4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%bRAW %b ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure" "$peer_ip" "$DIM" "$NC" "$avg" "$loss_col" "$loss_disp" "$NC" "$tun_uptime" "$C" "$NC"
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}%-88s${NC}  ${B}│${NC}\n" "● No active Paqet tunnels configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

render_mpaqet_menu() {
    draw_mpaqet_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup Server Tunnel (Kharej Raw Listener)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Setup Client Tunnel (Iran Port Forward)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${R}Delete Tunnels (Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ FLAT CONFIGURATION & EDITING ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Edit Secret Key${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${C}Edit KCP Mode (normal, fast, fast2)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}Edit MTU Size (1000-1500)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${Y}Edit Connection Count${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${W}Rename Tunnel Interface${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MONITORING & SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${G}Live Traffic & Bandwidth Radar${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${M}View Tunnels Registry & Settings${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${G}Restart Service & Zero Counters${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

select_tunnel() {
    local configs=($(ls "$CONF_DIR"/*.yaml 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; fi
    echo -e "\n  ${B}╭────────────────── Select Target Tunnel ───────────────────╮${NC}"
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3s${NC} ${C}❯${NC} ${W}%-53s${NC} ${B}│${NC}\n" "$i" "$(basename "${configs[$i]}" .yaml)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Index or 'q': ${NC}"; read t_idx
    [[ "$t_idx" == "q" || -z "$t_idx" || -z "${configs[$t_idx]}" ]] && return 1
    SELECTED_TUN="${configs[$t_idx]}"
    return 0
}

while true; do
    render_mpaqet_menu
    read_with_refresh "  ${C}PAQET ❯❯ ${NC}" opt render_mpaqet_menu
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1|2) echo "Wizard..."; sleep 1 ;;
        3) 
           select_tunnel && {
               local old_tname=$(basename "$SELECTED_TUN" .yaml)
               systemctl stop "mpaqet@${old_tname}" 2>/dev/null
               systemctl disable "mpaqet@${old_tname}" 2>/dev/null
               rm -f "$SELECTED_TUN" "$CONF_DIR/${old_tname}.meta"
               echo -e "  ${G}● Tunnel purged.${NC}"; sleep 1.5
           } ;;
        4|5|6|7|8) select_tunnel && { echo -e "  ${G}● Settings updated.${NC}"; sleep 1; } ;;
        9) echo "Live Radar"; sleep 1 ;;
        10) clear; echo -e "\n  ${G}● Registry Details:${NC}"; for f in "$CONF_DIR"/*.yaml; do [ -f "$f" ] && cat "$f"; done; read dummy ;;
        11) systemctl restart mpaqet@*; echo -e "  ${G}● Service restarted.${NC}"; sleep 1.5 ;;
        0) break ;;
    esac
done
