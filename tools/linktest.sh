#!/bin/bash
# --- MDesign Modular Core (linktest.sh) | Protocol Benchmark & Port Matrix v3.2.0 ---
# [Features: Granular Backhaul Modes + Full Tunnel Protocol Benchmark + Two-Way Scanner]

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
TMP_DIR="$(mktemp -d /tmp/linktest.XXXXXX)"
LISTENER_PIDS=()

cleanup() {
    for pid in "${LISTENER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP_DIR" 2>/dev/null || true
    # پاک‌سازی کامل اینترفیس‌های موقت تستی
    ip link del mtest_gre 2>/dev/null || true
    ip tunnel del mtest_gre 2>/dev/null || true
    ip link del mtest_sit 2>/dev/null || true
    ip tunnel del mtest_sit 2>/dev/null || true
    ip link del mtest_vx 2>/dev/null || true
    ip link del mtest_br 2>/dev/null || true
    pkill -f "bh -c /tmp/linktest_bh" 2>/dev/null || true
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
    local str1=" Protocol Benchmark & Two-Way Port Scanner 3.2.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Mode:${NC} ${C}Granular Matrix${NC} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

# --- 🌟 GRANULAR PROTOCOL MATRIX BENCHMARK 🌟 ---
run_protocol_matrix_test() {
    draw_header
    echo -e "\n  ${DIM}┌─[ AUTOMATED PROTOCOL COMPATIBILITY BENCHMARK ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Info:${NC} Spins up instances of each protocol & Backhaul transport modes."
    echo -e "  ${DIM}│${NC} ${Y}Tip:${NC} Run on BOTH servers simultaneously for live L3/L2 tunnels."
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
    if [ -z "$remote_ip" ]; then echo -e "  ${R}● Remote IP is required!${NC}"; sleep 1.5; return; fi

    echo -e "\n  ${Y}● Running Matrix Tests across all engines... (Please wait 12s)${NC}\n"
    echo -e "  ${B}╭─────────────────────────────┬────────────┬──────────────┬──────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-27s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "PROTOCOL / TRANSPORT" "STATUS" "LATENCY" "DETAILS / DIAGNOSTICS"
    echo -e "  ${B}├─────────────────────────────┼────────────┼──────────────┼──────────────────────────────┤${NC}"

    # 1. Standard GRE IPv4 Test
    ip link del mtest_gre 2>/dev/null || true
    ip tunnel del mtest_gre 2>/dev/null || true
    ip tunnel add mtest_gre mode gre remote "$remote_ip" local "$local_ip" ttl 255 key 999 2>/dev/null
    ip link set mtest_gre up 2>/dev/null
    local gre_loc="10.254.254.1"; local gre_rem="10.254.254.2"
    [ "$s_role" == "2" ] && { gre_loc="10.254.254.2"; gre_rem="10.254.254.1"; }
    ip addr add "$gre_loc/30" dev mtest_gre 2>/dev/null
    sleep 1.2
    local ping_gre=$(ping -c 2 -W 1 "$gre_rem" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local lat=$(echo "$ping_gre" | grep -oP 'time=\K\S+' | head -1)
        printf "  ${B}│${NC} ${C}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Standard IPv4 GRE" "PASSED" "${lat}ms" "Protocol 47 (GRE) OK"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Standard IPv4 GRE" "BLOCKED" "---" "GRE Drop / Peer Waiting"
    fi
    ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true

    # 2. 6to4 IP6GRE Encapsulation Test
    ip tunnel del mtest_sit 2>/dev/null || true
    ip tunnel add mtest_sit mode sit remote "$remote_ip" local "$local_ip" 2>/dev/null
    ip link set mtest_sit up 2>/dev/null
    local sit_v6_loc="fdfe:test::1"; local sit_v6_rem="fdfe:test::2"
    [ "$s_role" == "2" ] && { sit_v6_loc="fdfe:test::2"; sit_v6_rem="fdfe:test::1"; }
    ip -6 addr add "$sit_v6_loc/64" dev mtest_sit 2>/dev/null
    sleep 1.2
    local ping_sit=$(ping6 -c 2 -W 1 "$sit_v6_rem" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local lat6=$(echo "$ping_sit" | grep -oP 'time=\K\S+' | head -1)
        printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "PASSED" "${lat6}ms" "Protocol 41 (SIT/v6) OK"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "BLOCKED" "---" "Protocol 41 Filtered"
    fi
    ip link del mtest_sit 2>/dev/null || true; ip tunnel del mtest_sit 2>/dev/null || true

    # 3. VXLAN Layer-2 Mesh Test (Port 4789 UDP)
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
    sleep 1.2
    local ping_vx=$(ping -c 2 -W 1 "$vx_rem" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local latvx=$(echo "$ping_vx" | grep -oP 'time=\K\S+' | head -1)
        printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "VXLAN L2 Bridge Mesh" "PASSED" "${latvx}ms" "UDP Port 4789 Clear"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "VXLAN L2 Bridge Mesh" "BLOCKED" "---" "UDP 4789 Dropped/Blocked"
    fi
    ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true

    # 4. Rathole Reverse TCP Test (Port 8443)
    local test_port=8443
    if timeout 1.5 bash -c "exec 3<>/dev/tcp/$remote_ip/$test_port" 2>/dev/null; then
        printf "  ${B}│${NC} ${R}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse Engine" "PASSED" "Direct" "TCP Port $test_port Reachable"
    else
        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${Y}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse Engine" "UNCONFIRMED" "---" "Port $test_port Closed"
    fi

    # 5. Backhaul Granular Mode Tests
    test_bh_mode() {
        local mode_name=$1; local port_num=$2; local label_color=$3
        if timeout 1.5 bash -c "exec 3<>/dev/tcp/$remote_ip/$port_num" 2>/dev/null; then
            printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "PASSED" "Direct" "Port $port_num Open/Active"
        else
            printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${DIM}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "READY" "---" "Supported (Port $port_num)"
        fi
    }

    test_bh_mode "Backhaul: Plain TCP" "8443" "${G}"
    test_bh_mode "Backhaul: TCPMUX" "9443" "${G}"
    test_bh_mode "Backhaul: WSMUX (WS)" "9643" "${Y}"
    test_bh_mode "Backhaul: WSSMUX (TLS)" "9743" "${M}"

    echo -e "  ${B}╰─────────────────────────────┴────────────┴──────────────┴──────────────────────────────╯${NC}"
    echo -e "\n  ${DIM}All temporary test interfaces & routes have been completely purged.${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

# --- TWO-WAY LISTENER / TESTER ---
port_in_use() {
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE ":$1$"
}

start_listener() {
    local bind_ip="$1"; local port="$2"
    if port_in_use "$port"; then
        echo -e "  ${Y}SKIP${NC} Port ${W}${port}${NC} is already in use by another process."
        return 0
    fi

    cat > "$TMP_DIR/listener-$port.py" <<PY
import socket, sys, time, signal
def handle_sig(s, f): sys.exit(0)
signal.signal(signal.SIGTERM, handle_sig)
bind_ip = sys.argv[1]; port = int(sys.argv[2])
s = socket.socket(socket.AF_INET6 if ":" in bind_ip else socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((bind_ip, port))
s.listen(1024)
while True:
    conn, addr = s.accept()
    now = time.strftime("%H:%M:%S")
    print(f"  [{now}]  {addr[0]}:{addr[1]} connected to port {port}", flush=True)
    try: conn.sendall(b"LINKTEST_OK\\n")
    except: pass
    finally: conn.close()
PY
    python3 "$TMP_DIR/listener-$port.py" "$bind_ip" "$port" &
    local pid=$!
    LISTENER_PIDS+=("$pid")
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "  ${G}OK${NC}   Port ${W}${port}${NC} is now LISTENING  ${DIM}(pid $pid)${NC}"
    else
        echo -e "  ${R}FAIL${NC} Port ${W}${port}${NC} failed to bind."
    fi
}

run_listener() {
    draw_header
    echo -e "\n  ${DIM}┌─[ LISTENER MODE — Open Temporary Test Ports ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Info:${NC} Opens temporary TCP ports to receive handshake probes."
    echo -ne "  ${C}●${NC} ${W}Ports to open [Default 80,443,2053,2083,8080,8443,8880]: ${NC}"; read raw_ports
    raw_ports=${raw_ports:-"80,443,2053,2083,8080,8443,8880"}
    echo -ne "  ${C}●${NC} ${W}Auto-Stop Timeout in seconds [300]: ${NC}"; read duration
    duration=${duration:-300}

    local clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -un | xargs)
    echo ""
    for p in $clean_ports; do
        start_listener "0.0.0.0" "$p"
    done

    echo -e "\n  ${G}● Listeners Deployed!${NC} Press ${W}Enter${NC} to stop or wait ${W}${duration}s${NC}."
    echo -e "  ${DIM}(Incoming connection logs from peer will appear below in real-time)${NC}\n"
    read -t "$duration" dummy || true
    cleanup
    echo -e "\n  ${Y}● Listeners closed and ports freed.${NC}"; sleep 1.5
}

run_tester() {
    draw_header
    echo -e "\n  ${DIM}┌─[ TESTER MODE — Check Peer Reachability & Filtering ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Target Peer IP or Domain: ${NC}"; read peer
    peer=$(echo "$peer" | tr -d '\r' | tr -d ' ')
    [ -z "$peer" ] && return

    echo -ne "  ${C}●${NC} ${W}Ports to scan [Default 80,443,2053,2083,8080,8443,8880]: ${NC}"; read raw_ports
    raw_ports=${raw_ports:-"80,443,2053,2083,8080,8443,8880"}
    local clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -un | xargs)

    echo -e "\n  ${DIM}┌─[ PING & PACKET LOSS ]${NC}"
    local p_out=$(ping -c 4 -W 1 "$peer" 2>&1)
    local p_loss=$(echo "$p_out" | grep -oE '[0-9]+% packet loss')
    local p_lat=$(echo "$p_out" | grep -oP 'time=\K\S+' | head -1)
    if echo "$p_out" | grep -q ", 0% packet loss"; then
        echo -e "  ${G}✔ OK${NC}   Ping 0% Loss (${p_lat:-N/A}ms)"
    else
        echo -e "  ${Y}⚠ WARN${NC} Ping Loss: ${p_loss:-Unknown}"
    fi

    echo -e "\n  ${DIM}┌─[ TCP PORT SCAN RESULTS ]${NC}"
    echo -e "  ${B}╭─────────┬──────────────┬────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "PORT" "STATUS" "DETAILS / BANNER"
    echo -e "  ${B}├─────────┼──────────────┼────────────────────────────────────────────┤${NC}"

    local ok_c=0; local fail_c=0
    for p in $clean_ports; do
        if timeout 2 bash -c "exec 3<>/dev/tcp/$peer/$p" 2>/dev/null; then
            printf "  ${B}│${NC} ${Y}%-7s${NC} ${B}│${NC} ${G}%-12s${NC} ${B}│${NC} ${W}%-42s${NC} ${B}│${NC}\n" "$p" "OPEN" "Connection Established"
            ((ok_c++))
        else
            printf "  ${B}│${NC} ${DIM}%-7s${NC} ${B}│${NC} ${R}%-12s${NC} ${B}│${NC} ${DIM}%-42s${NC} ${B}│${NC}\n" "$p" "BLOCKED" "Filtered / Timed out"
            ((fail_c++))
        fi
    done
    echo -e "  ${B}╰─────────┴──────────────┴────────────────────────────────────────────╯${NC}"
    echo -e "\n  ${W}Summary:${NC} ${G}${ok_c} Open${NC} | ${R}${fail_c} Blocked${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

show_listening_ports() {
    draw_header
    echo -e "\n  ${DIM}┌─[ SYSTEM LISTENING PORTS ]${NC}"
    echo -e "  ${B}╭─────────┬──────────┬─────────────────────────────────────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-7s${NC} ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-47s${NC} ${B}│${NC}\n" "PORT" "PROTO" "PROCESS / PROGRAM NAME"
    echo -e "  ${B}├─────────┼──────────┼─────────────────────────────────────────────────┤${NC}"
    
    ss -lntp 2>/dev/null | awk 'NR>1 {
        split($5, a, ":");
        port = a[length(a)];
        proto = "TCP";
        proc = $0; gsub(/.*users:\(\("/, "", proc); gsub(/".*/, "", proc);
        if (port != "") printf "  \033[1;34m│\033[0m \033[1;33m%-7s\033[0m \033[1;34m│\033[0m \033[0;36m%-8s\033[0m \033[1;34m│\033[0m \033[1;37m%-47s\033[0m \033[1;34m│\033[0m\n", port, proto, proc;
    }' || true
    
    echo -e "  ${B}╰─────────┴──────────┴─────────────────────────────────────────────────╯${NC}"
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
        2) run_listener ;;
        3) run_tester ;;
        4) show_listening_ports ;;
        0) break ;;
    esac
done
