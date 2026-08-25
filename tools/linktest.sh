#!/bin/bash
# --- MDesign Modular Core (linktest.sh) | Strict Auto-Synced Benchmark v3.9.9 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
RESP_FILE="/tmp/mdesign_responder.py"
LISTENER_PIDS=()
SYNC_PORT=49999
SPEED_PORT=49998

cleanup() {
    for pid in "${LISTENER_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
    pkill -9 -f "mdesign_responder.py" 2>/dev/null || true
    rm -f "$RESP_FILE" 2>/dev/null || true
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
    local str1=" Strict Auto-Synced Benchmark & Speedtest 3.9.9 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Mode:${NC} ${C}Non-Freezing Speedlab${NC} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

verify_tunnel_ping() {
    local target_ip=$1
    local out=$(ping -c 3 -W 2 "$target_ip" 2>&1)
    if echo "$out" | grep -q ", 0% packet loss" || echo "$out" | grep -q ", 0.0% packet loss"; then
        local lat=$(echo "$out" | grep -oP 'time=\K[0-9.]+' | head -1)
        echo "OK|${lat:-1}ms"
    else
        echo "FAIL|---"
    fi
}

measure_tcp_speed() {
    local target_ip=$1
    local target_port=$2
    local duration=${3:-3}
    local parallel=${4:-1}
    local res

    # Each connection is measured independently and the aggregate throughput is returned.
    # The responder must implement the matching speed-test protocol.
    res=$(timeout $((duration + 5)) python3 - "$target_ip" "$target_port" "$duration" "$parallel" <<'PY'
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

target_ip = sys.argv[1]
target_port = int(sys.argv[2])
duration = float(sys.argv[3])
parallel = max(1, int(sys.argv[4]))

def worker():
    total = 0
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    s.settimeout(2.5)

    try:
        s.connect((target_ip, target_port))
        # Tell the temporary responder this is a throughput stream.
        s.sendall(b"MDESIGN-SPEED/1\n")
        s.settimeout(1.0)

        buf = b"X" * (1024 * 1024)
        start = time.monotonic()
        end = start + duration

        while time.monotonic() < end:
            try:
                sent = s.send(buf)
                if sent:
                    total += sent
                else:
                    break
            except (socket.timeout, BlockingIOError):
                continue

        elapsed = max(time.monotonic() - start, 0.001)
        return total, elapsed
    except Exception:
        return 0, 0.0
    finally:
        try:
            s.close()
        except Exception:
            pass

totals = 0
with ThreadPoolExecutor(max_workers=parallel) as pool:
    futures = [pool.submit(worker) for _ in range(parallel)]
    for f in as_completed(futures):
        b, _ = f.result()
        totals += b

if totals > 0:
    # Aggregate upload throughput in decimal Mbps.
    # The duration is fixed by the client; use it rather than connect/teardown time.
    mbps = (totals * 8.0) / (duration * 1_000_000.0)
    print(f"{mbps:.1f}")
else:
    print("ERR")
PY
    )

    echo "${res:-ERR}"
}

run_protocol_matrix_test() {
    draw_header

    # Required tools for the benchmark. Fail early instead of producing misleading results.
    local missing=()
    command -v ip >/dev/null 2>&1 || missing+=("iproute2/ip")
    command -v ping >/dev/null 2>&1 || missing+=("ping")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v timeout >/dev/null 2>&1 || missing+=("timeout")
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "\n  ${R}✖ Missing required command(s): ${missing[*]}${NC}"
        echo -e "  ${Y}Install the missing packages and run the benchmark again.${NC}"
        echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
        return
    fi
    echo -e "\n  ${DIM}┌─[ AUTO-SYNCED PROTOCOL BENCHMARK ]${NC}"
    echo -e "  ${DIM}│${NC} ${W}Info:${NC} Automated Step-by-Step handshake across both endpoints."
    echo -e "  ${DIM}├────────────────────────────────────────────────────────────────────────────${NC}"

    while true; do
        echo -ne "  ${C}●${NC} ${W}Server Role [1: IRAN (Responder) | 2: KHAREJ (Initiator) | q: Back]: ${NC}"; read s_role
        [[ "$s_role" =~ ^[12q]$ ]] && break
    done
    [[ "$s_role" == "q" ]] && return

    local local_ip=$(get_local_ip)
    echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read custom_l
    local_ip=${custom_l:-$local_ip}

    echo -ne "  ${C}●${NC} ${W}Remote Peer Public IP: ${NC}"; read remote_ip
    remote_ip=$(echo "$remote_ip" | tr -d '\r' | tr -d ' ')
    if [ -z "$remote_ip" ]; then echo -e "  ${R}● Remote Peer IP is required!${NC}"; sleep 1.5; return; fi

    if [ "$s_role" == "1" ]; then
        echo -e "\n  ${G}● IRAN Responder Active.${NC} Awaiting Sync Trigger from Kharej..."
        
        ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        ip tunnel add mtest_gre mode gre remote "$remote_ip" local "$local_ip" ttl 255 key 999 2>/dev/null
        ip link set mtest_gre up 2>/dev/null; ip addr add "10.254.254.1/30" dev mtest_gre 2>/dev/null

        ip tunnel del mtest_sit 2>/dev/null || true
        ip tunnel add mtest_sit mode sit remote "$remote_ip" local "$local_ip" 2>/dev/null
        ip link set mtest_sit up 2>/dev/null; ip -6 addr add "fdfe:test::1/64" dev mtest_sit 2>/dev/null

        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        local eth_iface=$(ip route get "$remote_ip" 2>/dev/null | awk '{print $5}' | head -n 1)
        [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
        ip link add mtest_br type bridge 2>/dev/null; ip link set mtest_br up 2>/dev/null
        ip link add mtest_vx type vxlan id 9999 dev "$eth_iface" remote "$remote_ip" dstport 4789 2>/dev/null
        ip link set mtest_vx master mtest_br 2>/dev/null; ip link set mtest_vx up 2>/dev/null
        ip addr add "10.253.253.1/24" dev mtest_br 2>/dev/null

        cat << 'PYEOF' > "$RESP_FILE"
import socket
import threading
import time

# Every channel gets its own temporary endpoint.
# The benchmark therefore never redirects all protocols to one shared SPEED_PORT.
ports = {
    8443: "Rathole Reverse TCP / Backhaul Plain TCP",
    8888: "Paqet Raw Packet KCP",
    9443: "Backhaul TCPMUX",
    9643: "Backhaul WSMUX (WS)",
    9743: "Backhaul WSSMUX (TLS)",
    49998: "Tunnel Speed Endpoint",
    49999: "Sync Endpoint",
}

def handle_client(c, addr, port):
    try:
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        c.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        c.settimeout(5.0)

        # Read the small benchmark preamble. If a normal TCP probe connects,
        # just keep the socket open briefly and then close it.
        header = c.recv(64)
        if header.startswith(b"MDESIGN-SPEED/1"):
            c.settimeout(2.0)
            total = 0
            start = time.monotonic()

            while True:
                try:
                    data = c.recv(1024 * 1024)
                    if not data:
                        break
                    total += len(data)
                except socket.timeout:
                    break
                except (ConnectionResetError, BrokenPipeError):
                    break

            elapsed = max(time.monotonic() - start, 0.001)
            mbps = (total * 8.0) / (elapsed * 1_000_000.0)
            # The client does not need this value; it is useful in logs/debugging.
            print(f"[speed] {addr[0]}:{addr[1]} -> {port} "
                  f"{total} bytes / {elapsed:.2f}s = {mbps:.1f} Mbps",
                  flush=True)
        else:
            # Keep compatibility with simple port reachability checks.
            time.sleep(0.25)
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass

def listen_port(p):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.bind(("0.0.0.0", p))
        s.listen(256)

        while True:
            c, addr = s.accept()
            threading.Thread(
                target=handle_client,
                args=(c, addr, p),
                daemon=True
            ).start()
    except Exception as e:
        print(f"[listener] port {p}: {e}", flush=True)

for p in ports:
    threading.Thread(target=listen_port, args=(p,), daemon=True).start()

while True:
    time.sleep(1)
PYEOF
        python3 "$RESP_FILE" &
        local resp_pid=$!
        LISTENER_PIDS+=("$resp_pid")

        echo -e "  ${C}✓ All Test Interfaces, Ports & Speedtest Listeners bound.${NC}"
        echo -e "  ${Y}● Go to KHAREJ server now and start Option 1.${NC}"
        echo -ne "\n  ${DIM}Press Enter when Kharej tests are finished to tear down...${NC}"; read dummy
        cleanup
        echo -e "  ${G}● Teardown complete. All test interfaces purged.${NC}"; sleep 1.5
        return

    else
        echo -e "\n  ${Y}● Synchronizing with IRAN server ($remote_ip)...${NC}"
        
        if ! timeout 3 bash -c "exec 3<>/dev/tcp/$remote_ip/$SYNC_PORT" 2>/dev/null; then
            echo -e "\n  ${R}✖ IRAN Server is NOT ready!${NC}"
            echo -e "  ${Y}Step 1:${NC} Open this menu on IRAN server and select ${W}1 (IRAN Responder)${NC}."
            echo -e "  ${Y}Step 2:${NC} Then run this option again on Kharej."
            echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy; return
        fi

        echo -e "  ${G}✔ Sync Established!${NC} Executing benchmark matrix...\n"
        echo -e "  ${B}╭─────────────────────────────┬────────────┬──────────────┬──────────────────────────────╮${NC}"
        printf "  ${B}│${NC} ${W}%-27s${NC} ${B}│${NC} ${W}%-10s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "PROTOCOL / TRANSPORT" "STATUS" "LATENCY" "DIAGNOSTICS & DETAILS"
        echo -e "  ${B}├─────────────────────────────┼────────────┼──────────────┼──────────────────────────────┤${NC}"

        local passed_protocols=()

        # 1. Standard GRE
        ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        ip tunnel add mtest_gre mode gre remote "$remote_ip" local "$local_ip" ttl 255 key 999 2>/dev/null
        ip link set mtest_gre up 2>/dev/null; ip addr add "10.254.254.2/30" dev mtest_gre 2>/dev/null
        sleep 1.2
        local res_gre=$(verify_tunnel_ping "10.254.254.1")
        if [[ "$res_gre" =~ ^OK ]]; then
            printf "  ${B}│${NC} ${C}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Standard IPv4 GRE" "PASSED" "${res_gre#OK|}" "Protocol 47 (GRE) Clean"
            passed_protocols+=("Standard GRE (L3)|10.254.254.1|$SPEED_PORT")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Standard IPv4 GRE" "BLOCKED" "---" "GRE Drop / ISP Filter"
            ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        fi

        # 2. 6to4 IP6GRE
        ip tunnel del mtest_sit 2>/dev/null || true
        ip tunnel add mtest_sit mode sit remote "$remote_ip" local "$local_ip" 2>/dev/null
        ip link set mtest_sit up 2>/dev/null; ip -6 addr add "fdfe:test::2/64" dev mtest_sit 2>/dev/null
        sleep 1.2
        local ping_sit=$(ping6 -c 3 -W 2 "fdfe:test::1" 2>&1)
        if echo "$ping_sit" | grep -q ", 0% packet loss" || echo "$ping_sit" | grep -q ", 0.0% packet loss"; then
            local lat6=$(echo "$ping_sit" | grep -oP 'time=\K[0-9.]+' | head -1)
            printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "PASSED" "${lat6:-1}ms" "Protocol 41 (SIT) Clean"
            passed_protocols+=("6to4 IP6GRE|fdfe:test::1|$SPEED_PORT")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "BLOCKED" "---" "Protocol 41 Filtered"
            ip link del mtest_sit 2>/dev/null || true; ip tunnel del mtest_sit 2>/dev/null || true
        fi

        # 3. VXLAN L2 Mesh
        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        local eth_iface=$(ip route get "$remote_ip" 2>/dev/null | awk '{print $5}' | head -n 1)
        [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
        ip link add mtest_br type bridge 2>/dev/null; ip link set mtest_br up 2>/dev/null
        ip link add mtest_vx type vxlan id 9999 dev "$eth_iface" remote "$remote_ip" dstport 4789 2>/dev/null
        ip link set mtest_vx master mtest_br 2>/dev/null; ip link set mtest_vx up 2>/dev/null
        ip addr add "10.253.253.2/24" dev mtest_br 2>/dev/null
        sleep 1.2
        local res_vx=$(verify_tunnel_ping "10.253.253.1")
        if [[ "$res_vx" =~ ^OK ]]; then
            printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "VXLAN L2 Bridge Mesh" "PASSED" "${res_vx#OK|}" "UDP 4789 Open & Fast"
            passed_protocols+=("VXLAN L2 Fabric|10.253.253.1|$SPEED_PORT")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "VXLAN L2 Bridge Mesh" "BLOCKED" "---" "UDP Port 4789 Dropped"
            ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        fi

        # 4. Rathole Reverse TCP
        if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/8443" 2>/dev/null; then
            printf "  ${B}│${NC} ${R}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse TCP" "PASSED" "Direct" "TCP Port 8443 Reachable"
            passed_protocols+=("Rathole TCP|$remote_ip|8443")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Rathole Reverse TCP" "BLOCKED" "---" "Port 8443 Filtered"
        fi

        # 5. Paqet Raw Packet (Port 8888)
        if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/8888" 2>/dev/null; then
            printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Paqet Raw Packet KCP" "PASSED" "Direct" "Raw Port 8888 Reachable"
            passed_protocols+=("Paqet Raw Packet|$remote_ip|8888")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Paqet Raw Packet KCP" "BLOCKED" "---" "Port 8888 Filtered"
        fi

        # 6. Backhaul Modes
        test_bh_mode() {
            local mode_name=$1; local port_num=$2; local label_color=$3
            if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/$port_num" 2>/dev/null; then
                printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "PASSED" "Direct" "Port $port_num Open"
                passed_protocols+=("$mode_name|$remote_ip|$port_num")
            else
                printf "  ${B}│${NC} %b%-27s%b ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "$label_color" "$mode_name" "$NC" "BLOCKED" "---" "Port $port_num Filtered"
            fi
        }

        test_bh_mode "Backhaul: Plain TCP" "8443" "${G}"
        test_bh_mode "Backhaul: TCPMUX" "9443" "${G}"
        test_bh_mode "Backhaul: WSMUX (WS)" "9643" "${Y}"
        test_bh_mode "Backhaul: WSSMUX (TLS)" "9743" "${M}"

        echo -e "  ${B}╰─────────────────────────────┴────────────┴──────────────┴──────────────────────────────╯${NC}"

        # =========================================================================
        # 🚀 LIVE SPEEDTEST ON PASSED PROTOCOLS
        # =========================================================================
        if [ ${#passed_protocols[@]} -gt 0 ]; then
            echo ""
            echo -ne "  ${C}●${NC} ${W}Run Live Speedtest benchmark on ${G}PASSED${W} channels? [y/N]: ${NC}"; read do_speed
            if [[ "${do_speed,,}" == "y" ]]; then
                echo -e "\n  ${Y}● Measuring Real-time Throughput (3s × 4 streams per channel)...${NC}\n"
                echo -e "  ${DIM}Upload benchmark: each PASSED channel is tested against its own endpoint/port.${NC}"
                echo -e "  ${B}╭─────────────────────────────┬──────────────────────────┬──────────────────────────────╮${NC}"
                printf "  ${B}│${NC} ${W}%-27s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "PASSED CHANNEL" "BANDWIDTH THROUGHPUT" "DIAGNOSTIC STATUS"
                echo -e "  ${B}├─────────────────────────────┼──────────────────────────┼──────────────────────────────┤${NC}"

                for item in "${passed_protocols[@]}"; do
                    IFS='|' read -r p_name p_host p_port <<< "$item"

                    local sp_val
                    sp_val=$(measure_tcp_speed "$p_host" "$p_port" 3 4)
                    if [ "$sp_val" != "ERR" ] && [ -n "$sp_val" ]; then
                        printf "  ${B}│${NC} ${C}%-27s${NC} ${B}│${NC} ${G}%-24s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "$p_name" "▲ ${sp_val} Mbps" "Measured Channel Throughput"
                    else
                        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-24s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "$p_name" "N/A" "Connection Timeout"
                    fi
                done
                echo -e "  ${B}╰─────────────────────────────┴──────────────────────────┴──────────────────────────────╯${NC}"
            fi
        fi

        cleanup
        echo -e "\n  ${DIM}Benchmark finished. All local test interfaces cleaned up.${NC}"
        echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
    fi
}

run_mtu_discovery() {
    draw_header
    echo -e "\n  ${DIM}┌─[ ACCURATE MTU & PACKET-LOSS DISCOVERY ]${NC}"
    echo -ne "  ${C}●${NC} ${W}Target Peer IP Address: ${NC}"; read target_ip
    target_ip=$(echo "$target_ip" | tr -d '\r' | tr -d ' ')
    [ -z "$target_ip" ] && return

    echo -e "\n  ${B}╭──────────┬──────────────┬─────────────┬──────────────┬─────────────────╮${NC}"
    printf "  ${B}│${NC} ${W}%-8s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-11s${NC} ${B}│${NC} ${W}%-12s${NC} ${B}│${NC} ${W}%-15s${NC} ${B}│${NC}\n" "MTU SIZE" "PAYLOAD" "PACKET LOSS" "PING (MS)" "STATUS"
    echo -e "  ${B}├──────────┼──────────────┼─────────────┼──────────────┼─────────────────┤${NC}"

    local test_sizes=("1472:1500" "1400:1428" "1350:1378" "1300:1328" "1280:1308" "1200:1228" "1100:1128" "1000:1028")
    for test in "${test_sizes[@]}"; do
        local payload="${test%%:*}"
        local mtu="${test##*:}"
        local ping_out=$(ping -c 4 -W 1 -M do -s "$payload" "$target_ip" 2>&1)
        local loss="100%"
        local avg_ping="---"
        local st_badge="${R}FAILED${NC}"

        if echo "$ping_out" | grep -q "0% packet loss"; then
            loss="0%"
            avg_ping=$(echo "$ping_out" | grep -oP 'time=\K[0-9.]+' | head -1)
            st_badge="${G}PERFECT${NC}"
        elif echo "$ping_out" | grep -q "packet loss"; then
            loss=$(echo "$ping_out" | grep -oP '[0-9]+% packet loss')
            st_badge="${Y}FRAGMENTED${NC}"
        fi

        printf "  ${B}│${NC} ${Y}%-8s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${W}%-11s${NC} ${B}│${NC} ${C}%-12s${NC} ${B}│${NC} %b%-15s%b ${B}│${NC}\n" "$mtu" "$payload" "$loss" "$avg_ping" "$st_badge" "$NC"
    done
    echo -e "  ${B}╰──────────┴──────────────┴─────────────┴──────────────┴─────────────────╯${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ LINK & PROTOCOL BENCHMARK ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Strict Auto-Synced Protocol Benchmark & Speedtest${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run Dynamic MTU & Loss Discovery Test${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Run as Listener (Open Temporary Test Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Run as Tester (Check Peer Ports & Filtering)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}View Active Listening Ports (OS Socket State)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}LINKTEST ❯❯ ${NC}"; read opt
    case $opt in
        1) run_protocol_matrix_test ;;
        2) run_mtu_discovery ;;
        3) 
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
        4) 
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
        5)
           draw_header
           echo -e "\n  ${DIM}┌─[ SYSTEM LISTENING PORTS ]${NC}"
           ss -lntp 2>/dev/null | awk 'NR>1 {split($5, a, ":"); port = a[length(a)]; proc = $0; gsub(/.*users:\(\("/, "", proc); gsub(/".*/, "", proc); if (port != "") printf "  %-7s %-47s\n", port, proc;}' || true
           echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy ;;
        0) break ;;
    esac
done
