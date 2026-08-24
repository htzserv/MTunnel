#!/bin/bash
# --- MDesign Modular Core (linktest.sh) | Strict 2-Way Protocol Benchmark v3.5.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
TMP_DIR="$(mktemp -d /tmp/linktest.XXXXXX)"
LISTENER_PIDS=()

cleanup() {
    for pid in "${LISTENER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP_DIR" 2>/dev/null || true
    ip link del mtest_gre 2>/dev/null || true
    ip tunnel del mtest_gre 2>/dev/null || true
    ip link del mtest_sit 2>/dev/null || true
    ip tunnel del mtest_sit 2>/dev/null || true
    ip link del mtest_vx 2>/dev/null || true
    ip link del mtest_br 2>/dev/null || true
}
trap cleanup EXIT INT TERM

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    local s_ip=$(get_local_ip)
    clear; echo ""
    local str1=" Strict 2-Way Tunnel Protocol Benchmark 3.5.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Mode:${NC} ${C}Strict 2-Way Lab${NC} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

verify_tunnel_ping() {
    local target_ip=$1
    local out=$(ping -c 2 -W 2 "$target_ip" 2>&1)
    if echo "$out" | grep -q ", 0% packet loss" || echo "$out" | grep -q ", 0.0% packet loss"; then
        local lat=$(echo "$out" | grep -oP 'time=\K[0-9.]+' | head -1)
        echo "OK|${lat:-1}ms"
    else
        echo "FAIL|---"
    fi
}

run_protocol_matrix_test() {
    draw_header
    echo -e "\n  ${DIM}┌─[ STRICT 2-WAY PROTOCOL BENCHMARK ]${NC}"
    echo -e "  ${DIM}│${NC} ${Y}Notice:${NC} For accurate network verification, open this benchmark menu"
    echo -e "  ${DIM}│${NC} on ${W}BOTH servers (Iran & Kharej)${NC} simultaneously."
    echo -e "  ${DIM}├────────────────────────────────────────────────────────────────────────────${NC}"

    while true; do
        echo -ne "  ${C}●${NC} ${W}Current Server Role [1: IRAN | 2: KHAREJ | q: Back]: ${NC}"; read s_role
        [[ "$s_role" =~ ^[12q]$ ]] && break
    done
    [[ "$s_role" == "q" ]] && return

    local local_ip=$(get_local_ip)
    echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_l
    local_ip=${custom_l:-$local_ip}

    echo -ne "  ${C}●${NC} ${W}Remote Peer Public IP: ${NC}"; read remote_ip
    remote_ip=$(echo "$remote_ip" | tr -d '\r' | tr -d ' ')
    if [ -z "$remote_ip" ]; then echo -e "  ${R}● Remote Peer IP is required!${NC}"; sleep 1.5; return; fi

    echo ""
    echo -e "  ${Y}Standby:${NC} Ensure the benchmark menu is active on the peer server."
    echo -ne "  ${G}Ready on both sides? (Press Enter to start benchmark): ${NC}"; read ready_go

    echo -e "\n  ${C}● Testing protocols in sequence...${NC}\n"
    echo -e "  ${B}╭─────────────────────────────┬────────────┬──────────────┬──────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-27s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "PROTOCOL / TRANSPORT" "STATUS" "LATENCY" "DIAGNOSTICS & DETAILS"
    echo -e "  ${B}├─────────────────────────────┼────────────┼──────────────┼──────────────────────────────┤${NC}"

    # 1. Standard GRE IPv4
    ip link del mtest_gre 2>/dev/null || true
    ip tunnel del mtest_gre 2>/dev/null || true
    ip tunnel add mtest_gre mode gre remote "$remote_ip" local "$local_ip" ttl 255 key 999 2>/dev/null
    ip link set mtest_gre up 2>/dev/null
    local gre_loc="10.254.254.1"; local gre_rem="10.254.254.2"
    [ "$s_role" == "2" ] && { gre_loc="10.254.254.2"; gre_rem="10.254.254.1"; }
    ip addr add "$gre_loc/30" dev mtest_gre 2>/dev/null
    sleep 2
    local res_gre=$(verify_tunnel_ping "$gre_rem")
    if [[ "$res_gre" =~ ^OK ]]; then
        local lat="${res_gre#OK|}"
        printf "  ${B}│${NC} ${C}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Standard IPv4 GRE" "PASSED" "$lat" "Protocol 47 (GRE) OK"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Standard IPv4 GRE" "BLOCKED" "---" "Packet Dropped / GRE Block"
    fi
    ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true

    # 2. 6to4 IP6GRE Encap
    ip tunnel del mtest_sit 2>/dev/null || true
    ip tunnel add mtest_sit mode sit remote "$remote_ip" local "$local_ip" 2>/dev/null
    ip link set mtest_sit up 2>/dev/null
    local sit_v6_loc="fdfe:test::1"; local sit_v6_rem="fdfe:test::2"
    [ "$s_role" == "2" ] && { sit_v6_loc="fdfe:test::2"; sit_v6_rem="fdfe:test::1"; }
    ip -6 addr add "$sit_v6_loc/64" dev mtest_sit 2>/dev/null
    sleep 2
    local ping_sit=$(ping6 -c 2 -W 2 "$sit_v6_rem" 2>&1)
    if echo "$ping_sit" | grep -q ", 0% packet loss" || echo "$ping_sit" | grep -q ", 0.0% packet loss"; then
        local lat6=$(echo "$ping_sit" | grep -oP 'time=\K[0-9.]+' | head -1)
        printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "PASSED" "${lat6:-1}ms" "Protocol 41 (SIT/v6) OK"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "BLOCKED" "---" "Protocol 41 Filtered"
    fi
    ip link del mtest_sit 2>/dev/null || true; ip tunnel del mtest_sit 2>/dev/null || true

    # 3. VXLAN Layer-2 Bridge Mesh
    ip link del mtest_vx 2>/dev/null || true
    ip link del mtest_br 2>/dev/null || true
    local eth_iface=$(ip route get "$remote_ip" 2>/dev/null | awk '{print $5}' | head -n 1)
    [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
    ip link add mtest_br type bridge 2>/dev/null; ip link set mtest_br up 2>/dev/null
    ip link add mtest_vx type vxlan id 9999 dev "$eth_iface" remote "$remote_ip" dstport 4789 2>/dev/null
    ip link set mtest_vx master mtest_br 2>/dev/null; ip link set mtest_vx up 2>/dev/null
    local vx_loc="10.253.253.1"; local vx_rem="10.253.253.2"
    [ "$s_role" == "2" ] && { vx_loc="10.253.253.2"; vx_rem="10.253.253.1"; }
    ip addr add "$vx_loc/24" dev mtest_br 2>/dev/null
    sleep 2
    local res_vx=$(verify_tunnel_ping "$vx_rem")
    if [[ "$res_vx" =~ ^OK ]]; then
        local latvx="${res_vx#OK|}"
        printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "VXLAN L2 Bridge Mesh" "PASSED" "$latvx" "UDP Port 4789 Clear"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "VXLAN L2 Bridge Mesh" "BLOCKED" "---" "UDP Port 4789 Dropped"
    fi
    ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true

    # 4. Rathole Reverse TCP
    local test_port=8443
    if [ "$s_role" == "1" ]; then
        python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', $test_port)); s.listen(1); s.settimeout(6); c,a=s.accept(); c.sendall(b'OK'); c.close(); s.close()" &
    fi
    sleep 1
    if [ "$s_role" == "2" ]; then
        if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/$test_port" 2>/dev/null; then
            printf "  ${B}│${NC} ${R}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse TCP" "PASSED" "Direct" "TCP Port $test_port Reachable"
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse TCP" "BLOCKED" "---" "Port $test_port Filtered"
        fi
    else
        printf "  ${B}│${NC} ${R}%-27s${NC} ${B}│${NC} ${C}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse TCP" "LISTENING" "---" "Awaiting Probe from Peer..."
    fi

    # 5. Backhaul Granular Mode Tests
    test_bh_mode() {
        local mode_name=$1; local port_num=$2; local label_color=$3
        if [ "$s_role" == "1" ]; then
            python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', $port_num)); s.listen(1); s.settimeout(6); c,a=s.accept(); c.sendall(b'OK'); c.close(); s.close()" &
        fi
        sleep 0.8
        if [ "$s_role" == "2" ]; then
            if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/$port_num" 2>/dev/null; then
                printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "PASSED" "Direct" "Port $port_num Reachable"
            else
                printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "BLOCKED" "---" "Port $port_num Filtered"
            fi
        else
            printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${C}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "LISTENING" "---" "Listening on Port $port_num"
        fi
    }

    test_bh_mode "Backhaul: Plain TCP" "8443" "${G}"
    test_bh_mode "Backhaul: TCPMUX" "9443" "${G}"
    test_bh_mode "Backhaul: WSMUX (WS)" "9643" "${Y}"
    test_bh_mode "Backhaul: WSSMUX (TLS)" "9743" "${M}"

    echo -e "  ${B}╰─────────────────────────────┴────────────┴──────────────┴──────────────────────────────╯${NC}"
    echo -e "\n  ${DIM}All temporary test interfaces and listeners have been cleanly purged.${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ LINK & PROTOCOL BENCHMARK ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Full Automated Tunnel Protocol Benchmark Matrix${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Listener (Open Temporary Test Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Run as Tester (Check Peer Ports & Filtering)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}View Active Listening Ports (OS Socket State)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}LINKTEST ❯❯ ${NC}"; read opt
    case $opt in
        1) run_protocol_matrix_test ;;
        2) 
           draw_header
           echo -ne "\n  ${C}●${NC} ${W}Target ports to open [e.g. 80,443,8443]: ${NC}"; read p_in
           p_in=${p_in:-"80,443,2053,2083,8080,8443,9743"}
           for p in $(echo "$p_in" | tr ',' ' '); do
               python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', $p)); s.listen(1024); [s.accept()[0].close() for _ in iter(int, 1)]" &
               LISTENER_PIDS+=($!)
               echo -e "  ${G}OK${NC} Port $p is now listening."
           done
           echo -ne "\n  ${Y}Press Enter to stop listeners...${NC}"; read dummy
           cleanup ;;
        3) 
           draw_header
           echo -ne "\n  ${C}●${NC} ${W}Target Peer IP: ${NC}"; read r_p
           echo -ne "  ${C}●${NC} ${W}Test Ports [e.g. 80,443,8443]: ${NC}"; read p_in
           p_in=${p_in:-"80,443,2053,2083,8080,8443,9743"}
           echo ""
           for p in $(echo "$p_in" | tr ',' ' '); do
               if timeout 2 bash -c "exec 3<>/dev/tcp/$r_p/$p" 2>/dev/null; then
                   echo -e "  ${G}✔ OPEN${NC}    Port $p on $r_p is reachable."
               else
                   echo -e "  ${R}✘ BLOCKED${NC} Port $p on $r_p is filtered/closed."
               fi
           done
           echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy ;;
        0) break ;;
    esac
done
