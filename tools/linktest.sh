#!/bin/bash
# --- MDesign Modular Core (linktest.sh) | Two-Way Link & Port Filter Scanner v2.0.0 ---

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
TMP_DIR="$(mktemp -d /tmp/linktest.XXXXXX)"
LISTENER_PIDS=()

cleanup() {
    for pid in "${LISTENER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP_DIR" 2>/dev/null || true
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
    local str1=" Two-Way Link & Port Filter Scanner 2.0.0 "
    local raw_len=$(( ${#str1} ))
    local pad_len=$(( 92 - raw_len - 38 )); [ "$pad_len" -lt 0 ] && pad_len=0
    local padding=$(printf '%*s' "$pad_len" "")

    echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${B}│${NC}${W}${str1}${NC}${B}│${NC}${DIM} IP:${NC} ${W}${s_ip}${NC} ${DIM}│ Mode:${NC} ${C}Port Diagnostics${NC} ${padding}${B}│${NC}"
    echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯${NC}"
}

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
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((bind_ip, port))
s.listen(1024)
while True:
    conn, addr = s.accept()
    now = time.strftime("%H:%M:%S")
    print(f"  [{now}]  {addr[0]}:{addr[1]} connected on port {port}", flush=True)
    try: conn.sendall(b"LINKTEST_OK\n")
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
    echo -ne "  ${C}●${NC} ${W}Ports to listen on (e.g. 80,443,8080,8443,2053,2083): ${NC}"; read raw_ports
    raw_ports=${raw_ports:-"80,443,2053,2083,8080,8443,8880"}
    echo -ne "  ${C}●${NC} ${W}Timeout in seconds (Auto-Stop) [300]: ${NC}"; read duration
    duration=${duration:-300}

    local clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -un | xargs)
    echo ""
    for p in $clean_ports; do
        start_listener "0.0.0.0" "$p"
    done

    echo -e "\n  ${G}● Active Listeners Deployed.${NC} Press ${W}Enter${NC} to stop or wait ${W}${duration}s${NC}."
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

    echo -ne "  ${C}●${NC} ${W}Ports to test (e.g. 80,443,8080,8443,2053,2083): ${NC}"; read raw_ports
    raw_ports=${raw_ports:-"80,443,2053,2083,8080,8443,8880"}
    local clean_ports=$(echo "$raw_ports" | tr ',' ' ' | xargs -n1 | sort -un | xargs)

    echo -e "\n  ${DIM}┌─[ PING & PACKET LOSS ]${NC}"
    local p_out=$(ping -c 4 -W 1 "$peer" 2>&1)
    local p_loss=$(echo "$p_out" | grep -oE '[0-9]+% packet loss')
    local p_lat=$(echo "$p_out" | grep -oP 'time=\K\S+' | head -1)
    if echo "$p_out" | grep -q ", 0% packet loss"; then
        echo -e "  ${G}OK${NC} Ping 0% Loss (${p_lat:-N/A}ms)"
    else
        echo -e "  ${Y}WARN${NC} Ping Loss: ${p_loss:-Unknown}"
    fi

    echo -e "\n  ${DIM}┌─[ TCP PORT SCAN RESULTS ]${NC}"
    local ok_c=0; local fail_c=0
    for p in $clean_ports; do
        if timeout 2 bash -c "exec 3<>\"/dev/tcp/$peer/$p\"" 2>/dev/null; then
            echo -e "  ${G}✔ OPEN${NC}    Port ${W}${p}${NC} is reachable on ${C}${peer}${NC}"
            ((ok_c++))
        else
            echo -e "  ${R}✘ BLOCKED${NC} Port ${W}${p}${NC} is filtered/closed on ${C}${peer}${NC}"
            ((fail_c++))
        fi
    done
    echo -e "  ${DIM}└────────────────────────────────────────────────────────${NC}"
    echo -e "  ${W}Summary:${NC} ${G}${ok_c} Open${NC} | ${R}${fail_c} Blocked${NC}"
    echo -ne "\n  ${DIM}Press Enter to return...${NC}"; read dummy
}

while true; do
    draw_header
    echo -e "\n  ${DIM}┌─[ LINK TEST ACTIONS ]${NC}\n  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Run as Listener (Open Temporary Test Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run as Tester (Check Peer Ports & Filtering)${NC}"
    echo -e "  ${DIM}│${NC}\n  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
    echo -ne "  ${C}LINKTEST ❯❯ ${NC}"; read opt
    case $opt in
        1) run_listener ;; 2) run_tester ;; 0) break ;;
    esac
done
