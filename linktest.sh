#!/bin/bash
# --- MTunnel LinkTest | Link & Protocol Benchmark v1.2.2 ---
# [Features: Protocol Matrix | TCP Speedtest | MTU/Loss Discovery | Port Reachability]
MODULE_VERSION="1.2.2"
MTUNNEL_REQUIRED_CORE_API=1
MTUNNEL_REQUIRED_LAYOUT_REV=2
umask 077

# MTUNNEL_COMMON_LOADER -- common API 1, required by this module.
mt_load_common() {
    local script_dir candidate
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    for candidate in \
        "$script_dir/core/common.sh" \
        "$script_dir/../core/common.sh" \
        /usr/lib/mtunnel/common.sh \
        /root/mtunnel/core/common.sh; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            source "$candidate" || return 1
            if [[ "${MTUNNEL_CORE_API:-}" == "${MTUNNEL_REQUIRED_CORE_API:-1}" && "${MTUNNEL_LAYOUT_REV:-}" == "${MTUNNEL_REQUIRED_LAYOUT_REV:-2}" ]]; then return 0; fi
            printf 'MTunnel LinkTest: incompatible shared core: %s\n' "$candidate" >&2
            return 1
        fi
    done
    echo 'MTunnel LinkTest: core/common.sh is missing. Reinstall the complete bundle.' >&2
    return 1
}
mt_load_common || exit 1
unset -f mt_load_common
if [ "$EUID" != 0 ]; then echo "Run MTunnel with sudo." >&2; exit 1; fi


















B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/linktest"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"
TMP_DIR="$(mktemp -d /tmp/linktest.XXXXXX)"
LISTENER_PIDS=()
SYNC_PORT=49999
SPEED_PORT=49998

mkdir -p "$LOCAL_DIR/packages" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    mt_install_files 755 "$0" "$INSTALL_PATH" || { echo "Cannot install module." >&2; exit 1; }
fi

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

check_requirements() {
    local missing=()
    for bin in ip python3 ping ss timeout; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "${R}✖ Missing required commands: ${missing[*]}${NC}"
        echo -e "${Y}Install them (e.g. iproute2, python3, iputils-ping, procps) and re-run.${NC}"
        exit 1
    fi
}
check_requirements

# --- ASYNC BACKGROUND UPDATE CHECKER ---
check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/linktest.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/linktest.sh${cb}"
    local remote_ver=""
    
    if command -v curl >/dev/null 2>&1; then
        remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(curl -fSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    elif command -v wget >/dev/null 2>&1; then
        remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$raw_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
        [ -z "$remote_ver" ] && remote_ver=$(wget -qO-  --header="Cache-Control: no-cache" --timeout=5 "$mirror_url" 2>/dev/null | grep -m1 '^MODULE_VERSION=' | cut -d'"' -f2)
    fi
    
    [ -n "$remote_ver" ] && echo "$remote_ver" > "$SECURE_TMP/.linktest_remote_ver"
}
check_update_bg &
# ---------------------------------------

self_update_module() {
    local src_opt custom_url dl_url tmp_file confirm
    local rel_path="linktest.sh"
    local cb="?t=$(date +%s)"
    
    local remote_v="Unknown"
    [ -f "$SECURE_TMP/.linktest_remote_ver" ] && remote_v=$(cat "$SECURE_TMP/.linktest_remote_ver" | tr -d '\r\n ')

    local gh_text="${C}Official GitHub Server${NC}"
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        gh_text="${C}Official GitHub Server${NC}    ${Y}(v${MODULE_VERSION} ➔ v${remote_v})${NC}"
    else
        gh_text="${C}Official GitHub Server${NC}    ${DIM}(v${MODULE_VERSION})${NC}"
    fi

    draw_header; echo -e "\n  ${DIM}┌─[ OTA Update (Linktest Engine) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}ParsPack Iranian Mirror${NC} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    
    [[ "$src_opt" =~ ^[1-4]$ ]] || return 0
    tmp_file=$(mktemp "$SECURE_TMP/update.XXXXXX") || return 1
    if [ "$src_opt" == 4 ]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste your code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then vi "$tmp_file"
        else rm -f "$tmp_file"; echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; return 1; fi
    else
        case "$src_opt" in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path";;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path";;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r dl_url;;
        esac
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if ! mt_download "$dl_url" "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Download failed. Installed module preserved.${NC}"; return 1; fi
    fi
    sed -i 's/\r$//' "$tmp_file"
    if ! mt_validate_script "$tmp_file"; then rm -f "$tmp_file"; echo -e "  ${R}✖ Invalid Bash module. Installed module preserved.${NC}"; return 1; fi
    local new_ver; new_ver=$(sed -n 's/^MODULE_VERSION="\([0-9.]*\)"$/\1/p' "$tmp_file")
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        
    [[ "${confirm,,}" == y || "${confirm,,}" == yes ]] || { echo -e "  ${Y}● Update cancelled by user.${NC}"; rm -f "$tmp_file"; return 0; }
    if ! mt_install_script "$tmp_file" "$rel_path" "$INSTALL_PATH" "$0"; then
        rm -f "$tmp_file"; echo -e "  ${R}✖ Update failed. Previous module preserved.${NC}"; return 1
    fi
    rm -f "$tmp_file"
    echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
    [ -z "${WATCHER_PID:-}" ] || kill "$WATCHER_PID" 2>/dev/null || true
    exec "$INSTALL_PATH" "$@"
}

ping6_compat() {
    if command -v ping6 >/dev/null 2>&1; then
        ping6 "$@"
    else
        ping -6 "$@"
    fi
}

get_local_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

draw_header() {
    clear
    mt_master_header_draw "$MODULE_VERSION"
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
    local target_ip=$1; local target_port=$2; local duration=3
    local res=$(TARGET_IP="$target_ip" TARGET_PORT="$target_port" DURATION="$duration" python3 -c "
import socket, time, os
target_ip = os.environ['TARGET_IP']
target_port = int(os.environ['TARGET_PORT'])
duration = float(os.environ['DURATION'])
s = None
try:
    s = socket.create_connection((target_ip, target_port), timeout=3)
    start = time.time()
    total_bytes = 0
    buf = b'X' * 65536
    while time.time() - start < duration:
        s.sendall(buf)
        total_bytes += len(buf)
    elapsed = time.time() - start
    speed_mbps = (total_bytes * 8) / (elapsed * 1000 * 1000)
    print(f'{speed_mbps:.1f}')
except Exception:
    print('ERR')
finally:
    if s is not None: s.close()
" 2>/dev/null)
    echo "${res:-ERR}"
}

run_protocol_matrix_test() {
    draw_header
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
        ip link set mtest_sit up 2>/dev/null; ip -6 addr add "fdfe:7465:7374::1/64" dev mtest_sit 2>/dev/null

        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true
        local eth_iface=$(ip route get "$remote_ip" 2>/dev/null | awk '{print $5}' | head -n 1)
        [ -z "$eth_iface" ] && eth_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n 1)
        ip link add mtest_br type bridge 2>/dev/null; ip link set mtest_br up 2>/dev/null
        ip link add mtest_vx type vxlan id 9999 dev "$eth_iface" remote "$remote_ip" dstport 4789 2>/dev/null
        ip link set mtest_vx master mtest_br 2>/dev/null; ip link set mtest_vx up 2>/dev/null
        ip addr add "10.253.253.1/24" dev mtest_br 2>/dev/null

        cat > "$TMP_DIR/responder.py" <<PY
import socket, sys, time, threading, os
ports = [8443, 8888, 9443, 9643, 9743, $SYNC_PORT, $SPEED_PORT]

def handle_client(c):
    try:
        while True:
            data = c.recv(65536)
            if not data: break
    except: pass
    finally: c.close()

def listen_port(p):
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.bind(('::', p))
        s.listen(128)
        while True:
            c, a = s.accept()
            threading.Thread(target=handle_client, args=(c,), daemon=True).start()
    except Exception as exc:
        print(f"Listener {p} failed: {exc}", file=sys.stderr, flush=True)
        os._exit(1)

for p in ports:
    threading.Thread(target=listen_port, args=(p,), daemon=True).start()

while True:
    time.sleep(1)
PY
        python3 "$TMP_DIR/responder.py" &
        local resp_pid=$!
        LISTENER_PIDS+=("$resp_pid")
        sleep 1
        if ! kill -0 "$resp_pid" 2>/dev/null; then wait "$resp_pid"; cleanup; echo 'Responder could not bind all ports.' >&2; return 1; fi

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
        sleep 1.5
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
        ip link set mtest_sit up 2>/dev/null; ip -6 addr add "fdfe:7465:7374::2/64" dev mtest_sit 2>/dev/null
        sleep 1.5
        local ping_sit=$(ping6_compat -c 3 -W 2 "fdfe:7465:7374::1" 2>&1)
        if echo "$ping_sit" | grep -q ", 0% packet loss" || echo "$ping_sit" | grep -q ", 0.0% packet loss"; then
            local lat6=$(echo "$ping_sit" | grep -oP 'time=\K[0-9.]+' | head -1)
            printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "6to4 IP6GRE Encap" "PASSED" "${lat6:-1}ms" "Protocol 41 (SIT) Clean"
            passed_protocols+=("6to4 IP6GRE|fdfe:7465:7374::1|$SPEED_PORT")
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
        sleep 1.5
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
            printf "  ${B}│${NC} ${R}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Rathole port precheck" "PASSED" "Direct" "Raw TCP :8443 reachable"
            passed_protocols+=("Rathole port precheck|$remote_ip|8443")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Rathole port precheck" "BLOCKED" "---" "Port 8443 Filtered"
        fi

        # 5. Paqet Raw Packet (Port 8888)
        if timeout 2 bash -c "exec 3<>/dev/tcp/$remote_ip/8888" 2>/dev/null; then
            printf "  ${B}│${NC} ${M}%-27s${NC} ${B}│${NC} ${G}%-10s${NC} ${B}│${NC} ${Y}%-12s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "Paqet port precheck" "PASSED" "Direct" "Raw TCP :8888 reachable"
            passed_protocols+=("Paqet port precheck|$remote_ip|8888")
        else
            printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-10s${NC} ${B}│${NC} ${DIM}%-12s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "Paqet port precheck" "BLOCKED" "---" "Port 8888 Filtered"
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

        test_bh_mode "Backhaul TCPMUX precheck" "9443" "${G}"
        test_bh_mode "Backhaul WSMUX precheck" "9643" "${Y}"
        test_bh_mode "Backhaul WSSMUX precheck" "9743" "${M}"

        echo -e "  ${B}╰─────────────────────────────┴────────────┴──────────────┴──────────────────────────────╯${NC}"

        if [ ${#passed_protocols[@]} -gt 0 ]; then
            echo ""
            echo -ne "  ${C}●${NC} ${W}Run Live Speedtest benchmark on ${G}PASSED${W} channels? [y/N]: ${NC}"; read do_speed
            if [[ "${do_speed,,}" == "y" ]]; then
                echo -e "\n  ${Y}● Measuring Real-time Throughput (3s per channel)...${NC}\n"
                echo -e "  ${B}╭─────────────────────────────┬──────────────────────────┬──────────────────────────────╮${NC}"
                printf "  ${B}│${NC} ${W}%-27s${NC} ${B}│${NC} ${W}%-24s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "PASSED CHANNEL" "BANDWIDTH THROUGHPUT" "DIAGNOSTIC STATUS"
                echo -e "  ${B}├─────────────────────────────┼──────────────────────────┼──────────────────────────────┤${NC}"

                for item in "${passed_protocols[@]}"; do
                    IFS='|' read -r p_name p_host p_port <<< "$item"

                    local sp_val=$(measure_tcp_speed "$p_host" "$p_port")
                    if [ "$sp_val" != "ERR" ] && [ -n "$sp_val" ]; then
                        printf "  ${B}│${NC} ${C}%-27s${NC} ${B}│${NC} ${G}%-24s${NC} ${B}│${NC} ${W}%-28s${NC} ${B}│${NC}\n" "$p_name" "▲ ${sp_val} Mbps" "Raw TCP throughput"
                    else
                        printf "  ${B}│${NC} ${DIM}%-27s${NC} ${B}│${NC} ${R}%-24s${NC} ${B}│${NC} ${DIM}%-28s${NC} ${B}│${NC}\n" "$p_name" "N/A" "Connection Timeout"
                    fi
                done
                echo -e "  ${B}╰─────────────────────────────┴──────────────────────────┴──────────────────────────────╯${NC}"
            fi
        fi

        ip link del mtest_gre 2>/dev/null || true; ip tunnel del mtest_gre 2>/dev/null || true
        ip link del mtest_sit 2>/dev/null || true; ip tunnel del mtest_sit 2>/dev/null || true
        ip link del mtest_vx 2>/dev/null || true; ip link del mtest_br 2>/dev/null || true

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

        if echo "$ping_out" | grep -qE '(^|, )[[:space:]]*0(\.0+)?% packet loss'; then
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
    badge=""
    if [ -f "$SECURE_TMP/.linktest_remote_ver" ]; then
        rv=$(cat "$SECURE_TMP/.linktest_remote_ver" | tr -d '\r\n ')
        if [ -n "$rv" ] && [ "$rv" != "Unknown" ] && [ "$rv" != "$MODULE_VERSION" ]; then
            badge=" ${Y}(Update Available: v${rv})${NC}"
        fi
    fi

    draw_header
    echo -e "\n  ${DIM}┌─[ LINK & PROTOCOL BENCHMARK ACTIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Strict Auto-Synced Protocol Benchmark & Speedtest${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${C}Run Dynamic MTU & Loss Discovery Test${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ DIAGNOSTIC UTILITIES ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Run as Listener (Open Temporary Test Ports)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Run as Tester (Check Peer Ports & Filtering)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${W}View Active Listening Ports (OS Socket State)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM OPERATIONS ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}OTA Update${NC}${badge}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"

    echo -ne "  ${C}LINKTEST ❯❯ ${NC}"; read opt
    case $opt in
        1) run_protocol_matrix_test ;;
        2) run_mtu_discovery ;;
        3) 
           draw_header
           echo -ne "\n  ${C}●${NC} ${W}Target ports to open [e.g. 80,443,8443]: ${NC}"; read p_in
           p_in=${p_in:-"80,443,2053,2083,8080,8443,9743"}
           for p in $(echo "$p_in" | tr ',' ' '); do
               mt_valid_port "$p" || { echo -e "  ${R}SKIP${NC} '$p' is not a valid port number."; continue; }
               LISTEN_PORT="$p" python3 -c "
import socket, os
port = int(os.environ['LISTEN_PORT'])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
s.listen(1024)
while True:
    c, _ = s.accept()
    c.close()
" &
               listener_pid=$!; LISTENER_PIDS+=("$listener_pid")
               sleep 0.1
               if ! kill -0 "$listener_pid" 2>/dev/null; then wait "$listener_pid"; echo "Port $p could not be opened." >&2; continue; fi
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
               if mt_tcp_probe "$r_p" "$p"; then
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
        6) self_update_module ;;
        0) break ;;
    esac
done
