#!/bin/bash
# --- MDesign Modular Core (minterface.sh) | Interface Mapper v3.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_configs() { ls /etc/mgre/tunnels/*.conf /etc/mgre/vxlan/*.conf /etc/ml2tp/tunnels/*.conf 2>/dev/null; }

detect_server_role() {
    local configs=($(get_configs))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "${DIM}Unknown (No Tunnels)${NC}"; return; fi
    source "${configs[0]}"
    [ "$TYPE" == "1" ] && echo -e "${G}IRAN (Access Node)${NC}" || echo -e "${M}KHAREJ (Gateway Node)${NC}"
}

draw_header() {
    local s_ip=$(get_local_ip); local role=$(detect_server_role)
    clear; echo ""
    local str1=" MDesign Interface Matrix 3.0.0 "
    local str2=" IP: $s_ip "
    local configs=($(get_configs)); local raw_role="Unknown (No Tunnels)"
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
    local l_spaces=$(printf '%*s' "$(( 28 - ${#l_raw} ))" "")
    local r_spaces=$(printf '%*s' "$(( 63 - ${#r_raw} ))" "")
    echo -e "  ${B}│${NC} ${l_col}${l_spaces} ${B}│${NC} ${r_col}${r_spaces} ${B}│${NC}"
}

render_matrix() {
    local configs=($(get_configs))
    if [ ${#configs[@]} -eq 0 ]; then echo -e "\n  ${R}● No network blueprints configured.${NC}"; sleep 2; return; fi

    echo -e "\n  ${Y}● Active Network Interface Blueprint:${NC}"
    for conf in "${configs[@]}"; do
        source "$conf"
        local is_vx=false; local is_l2tp=false; local t_name="$T_NAME"
        if [ -n "$BR_NAME" ]; then is_vx=true; t_name="$BR_NAME"; fi
        if [[ "$conf" == *"/ml2tp/"* ]]; then is_l2tp=true; fi

        local c_sub="${CORE_SUBNET:-10.76.${TUN_ID}}"
        local lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        local tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        
        local proto_lbl="IPv4 GRE Engine"; local title_color="${C}"
        [[ "$TUN_PROTO" == "6to4" ]] && { proto_lbl="6to4 IP6GRE Engine"; title_color="${M}"; }
        [[ "$is_vx" == true ]] && { proto_lbl="VXLAN L2 Bridge"; title_color="${M}"; }
        [[ "$is_l2tp" == true ]] && { proto_lbl="L2TPv3 Native Kernel Engine"; title_color="${Y}"; }

        local stat_raw="● DOWN"; local stat_color="${R}"; local sys_uptime="Offline"
        local state=$(cat /sys/class/net/$t_name/operstate 2>/dev/null)
        if ip link show "$t_name" >/dev/null 2>&1 && [[ "$state" == "up" || "$state" == "unknown" ]]; then
            stat_raw="● UP  "; stat_color="${G}"
            local created=$(stat -c %Y "/sys/class/net/$t_name" 2>/dev/null)
            if [ -n "$created" ]; then
                local diff=$(($(date +%s) - created))
                local d=$((diff / 86400)); local h=$(( (diff % 86400) / 3600 )); local m=$(( (diff % 3600) / 60 ))
                sys_uptime=""; [ "$d" -gt 0 ] && sys_uptime="${d}d "; [ "$h" -gt 0 ] && sys_uptime="${sys_uptime}${h}h "; sys_uptime="${sys_uptime}${m}m"
            fi
        fi

        local link_raw="○ OFFLINE"; local link_color="${R}"
        ping -c 1 -W 1 "$tip" >/dev/null 2>&1 && { link_raw="● ONLINE "; link_color="${G}"; }

        local h_ports=""; local g_ports=""; local subnets=("$c_sub")
        for v_lip in $(ip -4 addr show dev "$t_name" label "${t_name}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1); do
            subnets+=("$(echo "$v_lip" | cut -d'.' -f1-3)")
        done
        
        if [ -f "/etc/haproxy/haproxy.cfg" ]; then
            local h_tmp=""
            for sub in "${subnets[@]}"; do
                local p=$(grep "server srv_" /etc/haproxy/haproxy.cfg | grep "${sub}\." | awk '{print $2}' | cut -d'_' -f2)
                [ -n "$p" ] && h_tmp="$h_tmp\n$p"
            done
            h_ports=$(echo -e "$h_tmp" | grep -v '^$' | sort -un | paste -sd "," -)
        fi
        
        if [ -f "/etc/gost/config.json" ] && command -v jq >/dev/null 2>&1; then
            local g_tmp=""
            for sub in "${subnets[@]}"; do
                local p=$(jq -r '.ServeNodes[]?' /etc/gost/config.json 2>/dev/null | grep "${sub}\." | sed -E 's/tcp:\/\/:([0-9]+)\/.*/\1/')
                [ -n "$p" ] && g_tmp="$g_tmp\n$p"
            done
            g_ports=$(echo -e "$g_tmp" | grep -v '^$' | sort -un | paste -sd "," -)
        fi
        
        [ -z "$h_ports" ] && h_ports="None"; [ -z "$g_ports" ] && g_ports="None"
        [ ${#h_ports} -gt 50 ] && h_ports="${h_ports:0:47}..."
        [ ${#g_ports} -gt 50 ] && g_ports="${g_ports:0:47}..."

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        local left_part="▼ Interface: $t_name"
        local right_part="State: $stat_raw   Link: $link_raw   Uptime: $sys_uptime"
        local spaces=$(printf '%*s' "$(( 94 - ${#left_part} - ${#right_part} ))" "")
        echo -e "  ${B}│${NC} ${title_color}▼ Interface: ${W}$t_name${NC}${spaces}${DIM}State: ${stat_color}${stat_raw}${NC}   ${DIM}Link: ${link_color}${link_raw}${NC}   ${DIM}Uptime: ${W}${sys_uptime}${NC} ${B}│${NC}"
        echo -e "  ${B}├──────────────────────────────┬─────────────────────────────────────────────────────────────────┤${NC}"
        print_row_2col "Tunnel Infrastructure" "${C}Tunnel Infrastructure${NC}" "$proto_lbl" "${W}$proto_lbl${NC}"
        
        local l_pub=${LOCAL_PUB:-Unknown}; local r_pub=${REMOTE_PUB:-${T_REMOTE:-Unknown}}
        print_row_2col "Public Endpoint IPs" "${DIM}Public Endpoint IPs${NC}" "Local: $l_pub   Remote: $r_pub" "${DIM}Local:${NC} ${W}$l_pub${NC}   ${DIM}Remote:${NC} ${W}$r_pub${NC}"
        echo -e "  ${B}├──────────────────────────────┼─────────────────────────────────────────────────────────────────┤${NC}"
        print_row_2col "Core IPv4 Network" "${DIM}Core IPv4 Network${NC}" "Local: $lip   Remote: $tip" "${DIM}Local:${NC} ${G}$lip${NC}   ${DIM}Remote:${NC} ${Y}$tip${NC}"
        print_row_2col "Active Port Mappings" "${Y}Active Port Mappings${NC}" "HAProxy: $h_ports" "${C}HAProxy:${NC} ${W}$h_ports${NC}"
        print_row_2col "" "" "Gost   : $g_ports" "${M}Gost   :${NC} ${W}$g_ports${NC}"
        
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
