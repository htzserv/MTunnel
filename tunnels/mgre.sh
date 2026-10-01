#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v6.0.1 ---
# [Features: Symmetric Telemetry Header | Compact Peer Link | Dynamic MTU | Instant MSS Engine]
# [v6.0.0: Quote-safe iptables cleanup | Safe index pickers | Cross-tool subnet guard | SSH-safe DNAT
#          | Correct MTU math | IPsec ESP | Firewall Guard | Watchdog + LB health | Auto-MTU | Traffic | Backup | CLI]

MODULE_VERSION="6.0.1"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[0;36m'; M='\033[1;35m'; W='\033[1;37m'; DIM='\033[2;37m'; NC='\033[0m'
INSTALL_PATH="/usr/bin/mgre"
CONF_DIR="/etc/mgre/tunnels"
SERVICE_FILE="/etc/systemd/system/mgre.service"
LOCAL_DIR="/root/mtunnel"
SECURE_TMP="$LOCAL_DIR/tmp"

[ -f "/usr/local/bin/mgre" ] && rm -f "/usr/local/bin/mgre" 2>/dev/null

mkdir -p "$CONF_DIR" "$LOCAL_DIR/packages" "$LOCAL_DIR/tunnels" "$SECURE_TMP" 2>/dev/null
chmod 700 "$SECURE_TMP" 2>/dev/null

# ======================================================================
# [ v-next ] Shared Hardening Helpers (validation, iptables, guard, xfrm)
# ======================================================================
MT_ROOT_CONF="/etc/mgre"
GUARD_FLAG="$MT_ROOT_CONF/.mgre_guard"
WD_SERVICE="/etc/systemd/system/mgre-watchdog.service"
WD_TIMER="/etc/systemd/system/mgre-watchdog.timer"
WD_LOG="/var/log/mgre-watchdog.log"
BACKUP_DIR="$LOCAL_DIR/backups"

is_uint()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_ipv4()  {
    local ip="$1" x; local -a o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra o <<< "$ip"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
}
is_subnet3() {
    local s="$1" x; local -a o
    [[ "$s" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra o <<< "$s"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
}

# Safe single-variable write into a flat conf (adds the key if missing)
set_conf_var() {
    local file="$1" key="$2" val="$3"
    [ -f "$file" ] || return 1
    grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null
    echo "${key}=${val}" >> "${file}.tmp"
    mv -f "${file}.tmp" "$file"; chmod 600 "$file" 2>/dev/null
}

# Pick an item from a list safely. Usage: pick_index "<input>" <count>  -> echoes zero-based idx
pick_index() {
    local in="$1" cnt="$2"
    is_uint "$in" || return 1
    [ "$in" -ge 1 ] && [ "$in" -le "$cnt" ] || return 1
    echo $((in - 1))
}

# Delete all rules carrying an exact comment tag (quote-safe, fixes rule leaks)
ipt_delete_tagged() {
    local tbl="$1" ch="$2" tag="$3" r
    iptables -t "$tbl" -S "$ch" 2>/dev/null | grep -E -- "--comment \"?${tag}\"?( |$)" | sed 's/^-A /-D /' | \
    while IFS= read -r r; do
        [ -n "$r" ] && echo "$r" | xargs iptables -t "$tbl" 2>/dev/null
    done
}

# Cross-tool subnet collision check (MGRE + MXLAN + live routes)
subnet_in_use() {
    local sub="$1" exclude="$2" f
    for f in "$MT_ROOT_CONF"/tunnels/*.conf "$MT_ROOT_CONF"/vxlan/*.conf; do
        [ -f "$f" ] || continue
        [ -n "$exclude" ] && [ "$(readlink -f "$f")" == "$(readlink -f "$exclude")" ] && continue
        grep -q "^CORE_SUBNET=${sub}$" "$f" 2>/dev/null && return 0
    done
    ip -4 route show 2>/dev/null | grep -qE "^${sub//./\\.}\.[0-9]+(/| )" && return 0
    return 1
}

get_ssh_ports() {
    local p
    p=$(ss -tlnpH 2>/dev/null | grep -w 'sshd' | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')
    echo "${p:-22}"
}

# Clean a port list (supports ranges a:b). For TCP it refuses to hijack the SSH port.
sanitize_ports() {
    local raw="$1" proto="$2" out="" item a b s skip
    local ssh_ports; ssh_ports=$(get_ssh_ports)
    raw=$(echo "$raw" | tr -dc '0-9,:')
    local IFS=','
    for item in $raw; do
        [ -z "$item" ] && continue
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
            { [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$a" -ge "$b" ]; } && { echo -e "  ${Y}● Skipped invalid range: $item${NC}" >&2; continue; }
            item="${a}:${b}"
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            a=$((10#$item)); b=$a
            { [ "$a" -lt 1 ] || [ "$a" -gt 65535 ]; } && { echo -e "  ${Y}● Skipped invalid port: $item${NC}" >&2; continue; }
            item="$a"
        else
            echo -e "  ${Y}● Skipped invalid entry: $item${NC}" >&2; continue
        fi
        skip=0
        if [ "$proto" == "tcp" ]; then
            IFS=' '
            for s in $ssh_ports; do
                if [ "$s" -ge "$a" ] && [ "$s" -le "$b" ]; then skip=1; fi
            done
            IFS=','
            [ "$skip" -eq 1 ] && { echo -e "  ${R}● Refused '$item': it contains this server's SSH port (lock-out protection).${NC}" >&2; continue; }
        fi
        out+="${item},"
    done
    echo "${out%,}"
}

# Derive vIP pair targets exactly like the original engine (keeps peer compatibility)
vip_targets() {
    local key="$1" max="$2" type="$3" i hash rs o1 o2 o3
    is_uint "$max" || return
    for ((i=0; i<max; i++)); do
        hash=$(echo "${key}_${i}" | sha256sum)
        rs=$(( 0x${hash:0:2} % 3 ))
        if [[ "$rs" == "0" ]]; then o1="10"; o2=$(( (0x${hash:2:2} % 254) + 1 ))
        elif [[ "$rs" == "1" ]]; then o1="172"; o2=$(( (0x${hash:2:2} % 16) + 16 ))
        else o1="192"; o2="168"; fi
        o3=$(( (0x${hash:4:2} % 254) + 1 ))
        if [ "$type" == "1" ]; then echo "$o1.$o2.$o3.1 $o1.$o2.$o3.2"; else echo "$o1.$o2.$o3.2 $o1.$o2.$o3.1"; fi
    done
}

# NAT / Load-Balancer builder. DNAT only hits traffic addressed to THIS host and never traffic coming from the tunnel itself.
build_fwd_rules() {
    local tag="$1" tif="$2" tcp="$3" udp="$4" lb="$5" deadf="$6"; shift 6
    local -a targets=("$@") live=()
    local t proto list p idx n rem dst
    if [[ "$lb" == "1" ]]; then
        for t in "${targets[@]}"; do
            if [ -s "$deadf" ] && grep -qxF "$t" "$deadf"; then continue; fi
            live+=("$t")
        done
        [ ${#live[@]} -eq 0 ] && live=("${targets[0]}")
    else
        live=("${targets[0]}")
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    n=${#live[@]}
    for proto in tcp udp; do
        list="$tcp"; [ "$proto" == "udp" ] && list="$udp"
        [ -z "$list" ] && continue
        local -a PARR=()
        IFS=',' read -ra PARR <<< "$list"
        for p in "${PARR[@]}"; do
            p=$(echo "$p" | tr -dc '0-9:'); [ -z "$p" ] && continue
            for ((idx=0; idx<n; idx++)); do
                dst="${live[$idx]}"; rem=$((n - idx))
                if [ "$rem" -gt 1 ]; then
                    iptables -t nat -A PREROUTING ! -i "$tif" -m addrtype --dst-type LOCAL -p "$proto" -m "$proto" --dport "$p" -m statistic --mode nth --every "$rem" --packet 0 -m comment --comment "$tag" -j DNAT --to-destination "$dst" 2>/dev/null
                else
                    iptables -t nat -A PREROUTING ! -i "$tif" -m addrtype --dst-type LOCAL -p "$proto" -m "$proto" --dport "$p" -m comment --comment "$tag" -j DNAT --to-destination "$dst" 2>/dev/null
                fi
                iptables -t nat -A POSTROUTING -o "$tif" -p "$proto" -m "$proto" -d "$dst" --dport "$p" -m comment --comment "$tag" -j MASQUERADE 2>/dev/null
                iptables -t filter -A FORWARD -o "$tif" -p "$proto" -d "$dst" --dport "$p" -m comment --comment "$tag" -j ACCEPT 2>/dev/null
            done
        done
    done
}

# ---- IPsec (ESP transport) encryption, keys derived from the Master Token on both peers ----
xfrm_state_file() { echo "$SECURE_TMP/.mgre_xfrm_$1"; }

xfrm_clear() {
    local name="$1" sf; sf=$(xfrm_state_file "$name")
    [ -f "$sf" ] || return 0
    local line
    while IFS= read -r line; do [ -n "$line" ] && eval "$line" >/dev/null 2>&1; done < "$sf"
    rm -f "$sf"
}

# Usage: xfrm_apply <name> <type 1|2> <local> <remote> <token> <selector...>
xfrm_apply() {
    local name="$1" type="$2" lip="$3" rip="$4" tok="$5"; shift 5
    local sel="$*"
    xfrm_clear "$name"
    [ -z "$tok" ] || [ -z "$lip" ] || [ -z "$rip" ] && return 1
    ip -4 addr show 2>/dev/null | grep -qF "inet $lip/" || { echo "  [xfrm] $name: local IP $lip not on this host (NAT?), encryption skipped" >&2; return 1; }
    local h ab ba reqid ek_ab ak_ab ek_ba ak_ba spi_out spi_in ek_out ak_out ek_in ak_in
    h=$(echo -n "mtun_esp_${tok}" | sha256sum)
    ab=$(printf '0x%08x' $(( 16#${h:0:7} + 256 )))
    ba=$(printf '0x%08x' $(( 16#${h:8:7} + 256 )))
    reqid=$(( 16#${h:16:6} + 1 ))
    ek_ab=$(echo -n "enc_ab_${tok}" | sha256sum | cut -c1-64); ak_ab=$(echo -n "auth_ab_${tok}" | sha256sum | cut -c1-64)
    ek_ba=$(echo -n "enc_ba_${tok}" | sha256sum | cut -c1-64); ak_ba=$(echo -n "auth_ba_${tok}" | sha256sum | cut -c1-64)
    if [ "$type" == "1" ]; then spi_out=$ab; ek_out=$ek_ab; ak_out=$ak_ab; spi_in=$ba; ek_in=$ek_ba; ak_in=$ak_ba
    else spi_out=$ba; ek_out=$ek_ba; ak_out=$ak_ba; spi_in=$ab; ek_in=$ek_ab; ak_in=$ak_ab; fi

    ip xfrm state add src "$lip" dst "$rip" proto esp spi "$spi_out" reqid "$reqid" mode transport replay-window 0 \
        auth-trunc 'hmac(sha256)' "0x$ak_out" 128 enc 'cbc(aes)' "0x$ek_out" 2>/dev/null || return 1
    ip xfrm state add src "$rip" dst "$lip" proto esp spi "$spi_in" reqid "$reqid" mode transport replay-window 0 \
        auth-trunc 'hmac(sha256)' "0x$ak_in" 128 enc 'cbc(aes)' "0x$ek_in" 2>/dev/null || return 1
    ip xfrm policy add src "$lip/32" dst "$rip/32" $sel dir out tmpl src "$lip" dst "$rip" proto esp reqid "$reqid" mode transport 2>/dev/null
    ip xfrm policy add src "$rip/32" dst "$lip/32" $sel dir in  tmpl src "$rip" dst "$lip" proto esp reqid "$reqid" mode transport 2>/dev/null
    {
        echo "ip xfrm policy delete src $lip/32 dst $rip/32 $sel dir out"
        echo "ip xfrm policy delete src $rip/32 dst $lip/32 $sel dir in"
        echo "ip xfrm state delete src $lip dst $rip proto esp spi $spi_out"
        echo "ip xfrm state delete src $rip dst $lip proto esp spi $spi_in"
    } > "$(xfrm_state_file "$name")"
    chmod 600 "$(xfrm_state_file "$name")" 2>/dev/null
    return 0
}

# ---- Path MTU probe towards the remote public IP (needs ICMP echo on peer) ----
probe_path_mtu() {
    local dst="$1" lo=500 hi=1472 mid best=0
    ping -c1 -W1 -M do -s "$lo" "$dst" >/dev/null 2>&1 || { echo 0; return; }
    best=$lo
    while [ "$lo" -le "$hi" ]; do
        mid=$(( (lo + hi) / 2 ))
        if ping -c1 -W1 -M do -s "$mid" "$dst" >/dev/null 2>&1; then best=$mid; lo=$((mid + 1)); else hi=$((mid - 1)); fi
    done
    echo $((best + 28))
}

auto_mtu_for_gre() {
    local dst="$1" proto="$2" pmtu overhead min_mtu max_mtu fallback mtu
    read -r min_mtu max_mtu fallback <<< "$(mgre_mtu_limits "$proto")"
    pmtu=$(probe_path_mtu "$dst")
    overhead=28
    [ "$proto" == "6to4" ] && overhead=68
    if [ "$pmtu" -eq 0 ]; then
        echo "  ● Peer did not answer the MTU probe; using safe fallback MTU $fallback." >&2
        echo "$fallback"
        return
    fi
    mtu=$((pmtu - overhead))
    [ "$mtu" -gt "$max_mtu" ] && mtu="$max_mtu"
    [ "$mtu" -lt "$min_mtu" ] && mtu="$min_mtu"
    echo "  ● Detected path MTU $pmtu; selected tunnel MTU $mtu (overhead $overhead bytes)." >&2
    echo "$mtu"
}

human_rate() {
    local b="$1"
    awk -v b="$b" 'BEGIN { bits=b*8; if (bits>=1e9) printf "%.2f Gbps", bits/1e9; else if (bits>=1e6) printf "%.2f Mbps", bits/1e6; else if (bits>=1e3) printf "%.1f Kbps", bits/1e3; else printf "%d bps", bits }'
}
human_bytes() {
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'
}

# ---- Watchdog (systemd timer) ----
wd_log() { echo "[$(date '+%F %T')] $*" >> "$WD_LOG"; }

watchdog_enable() {
    cat > "$WD_SERVICE" <<EOS
[Unit]
Description=MGRE Watchdog (auto-heal & LB health)
After=network-online.target
[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --watchdog
EOS
    cat > "$WD_TIMER" <<EOS
[Unit]
Description=MGRE Watchdog Timer
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOS
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now mgre-watchdog.timer >/dev/null 2>&1
}
watchdog_disable() {
    systemctl disable --now mgre-watchdog.timer >/dev/null 2>&1
    rm -f "$WD_SERVICE" "$WD_TIMER"
    systemctl daemon-reload 2>/dev/null
}
watchdog_is_on() { systemctl is-active --quiet mgre-watchdog.timer 2>/dev/null; }

# ---- Backup / Restore ----
backup_configs() {
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    local f="$BACKUP_DIR/mgre-$(date +%Y%m%d-%H%M%S).tgz"
    tar czf "$f" -C "$(dirname "$CONF_DIR")" "$(basename "$CONF_DIR")" 2>/dev/null && chmod 600 "$f" && echo "$f"
}
# ======================================================================


if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

UPDATE_CHECK_INTERVAL=60
PING_CHECK_INTERVAL=5

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local redraw_func="$3"
    local buffer=""
    local char rc
    local last_refresh
    last_refresh=$(date +%s)

    echo -ne "$prompt"

    while true; do
        local now
        now=$(date +%s)
        if [ $((now - last_refresh)) -ge "$PING_CHECK_INTERVAL" ]; then
            last_refresh=$now
            if [ -z "$buffer" ] && [ -n "$redraw_func" ]; then
                "$redraw_func"
                echo -ne "$prompt$buffer"
            fi
        fi

        IFS= read -rsn1 -t 0.2 char
        rc=$?

        if [ $rc -ne 0 ]; then
            continue
        fi

        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then
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

fetch_remote_version() {
    local url="$1" payload version=""
    if command -v curl >/dev/null 2>&1; then
        payload=$(curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 3 --max-time 8 "$url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        payload=$(wget -qO- --header="Cache-Control: no-cache" --timeout=8 "$url" 2>/dev/null) || return 1
    else
        return 1
    fi
    version=$(printf '%s\n' "$payload" | sed -n 's/^MODULE_VERSION="\([^" ]*\)".*/\1/p' | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

check_update_bg() {
    local cb="?t=$(date +%s)"
    local raw_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/tunnels/mgre.sh${cb}"
    local mirror_url="https://c107328.parspack.net/c107328/MTunnel/tunnels/mgre.sh${cb}"
    local gh_ver="" mirror_ver=""

    gh_ver=$(fetch_remote_version "$raw_url")
    mirror_ver=$(fetch_remote_version "$mirror_url")
    rm -f "$SECURE_TMP/.mgre_remote_ver_github" "$SECURE_TMP/.mgre_remote_ver_mirror"
    [ -n "$gh_ver" ] && printf '%s\n' "$gh_ver" > "$SECURE_TMP/.mgre_remote_ver_github"
    [ -n "$mirror_ver" ] && printf '%s\n' "$mirror_ver" > "$SECURE_TMP/.mgre_remote_ver_mirror"
}


update_watcher_loop() {
    while true; do
        check_update_bg
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}
if [[ "$1" != --* ]]; then
    update_watcher_loop &
    WATCHER_PID=$!
fi

check_ping_bg() {
    local count=0
    local conf TYPE T_NAME CORE_SUBNET tip res loss avg
    > "$SECURE_TMP/.mgre_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; CORE_SUBNET=""; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        ((count++))
        [ "$count" -gt 3 ] && break

        tip=$([ "$TYPE" == "1" ] && echo "${CORE_SUBNET}.2" || echo "${CORE_SUBNET}.1")
        res=$(timeout 2 ping -c 3 -i 0.2 -W 1 "$tip" 2>/dev/null)
        loss=$(echo "$res" | grep -oP '[0-9]+(?=% packet loss)')
        [ -z "$loss" ] && loss="100"
        
        avg="---"
        if echo "$res" | grep -q "min/avg/max"; then
            avg=$(echo "$res" | grep -oP 'min/avg/max(/mdev)? = \K[^/]+/[^/]+' | cut -d/ -f2)
            if [ -n "$avg" ]; then
                avg=$(awk -v v="$avg" 'BEGIN {printf "%.0f", v}')
                avg="${avg}ms"
            fi
        fi
        echo "${T_NAME}|${avg}|${loss}" >> "$SECURE_TMP/.mgre_stats_cache.tmp"
    done
    mv -f "$SECURE_TMP/.mgre_stats_cache.tmp" "$SECURE_TMP/.mgre_stats_cache" 2>/dev/null
}

ping_watcher_loop() {
    while true; do
        check_ping_bg
        sleep "$PING_CHECK_INTERVAL"
    done
}
if [[ "$1" != --* ]]; then
    ping_watcher_loop &
    PING_WATCHER_PID=$!
fi

trap 'kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null' EXIT

get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip:-Unknown}"
}

get_pure_tun_name() {
    local pure="$1"
    pure="${pure#gre6ir}"; pure="${pure#gre6kh}"; pure="${pure#greir}"; pure="${pure#grekh}"
    echo "${pure:-$1}"
}

get_iface_uptime() {
    local iface="$1"
    if [ ! -d "/sys/class/net/$iface" ] || [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" == "down" ]; then
        echo "DOWN"
        return
    fi
    local sys_uptime if_sec delta d h m
    sys_uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    if_sec=$(ip -s -d link show "$iface" 2>/dev/null | grep -oP 'trans_start \K[0-9]+')
    delta=0
    if [ -n "$if_sec" ] && [ "$if_sec" -gt 0 ]; then
        delta=$(( (sys_uptime * 100 - if_sec) / 100 ))
        [ "$delta" -lt 0 ] && delta=0
    else
        local created now
        created=$(stat -c %Y "/sys/class/net/$iface" 2>/dev/null)
        now=$(date +%s)
        delta=$(( now - created ))
        [ "$delta" -lt 0 ] && delta=0
    fi
    d=$(( delta / 86400 )); h=$(( (delta % 86400) / 3600 )); m=$(( (delta % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf "%dd %02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm" "$m"; fi
}

draw_mgre_header() {
    local s_ip active_tunnels=0 conf
    s_ip=$(get_local_ip)
    s_ip="${s_ip:0:25}"
    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        T_NAME=""; source "$conf" 2>/dev/null
        if ip link show "$T_NAME" >/dev/null 2>&1 && [ "$(cat "/sys/class/net/$T_NAME/operstate" 2>/dev/null)" != "down" ]; then
            ((active_tunnels++))
        fi
    done

    clear; echo ""
    local border
    printf -v border '%*s' 117 ''
    border="${border// /─}"

    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-34.34s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-25.25s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3.3s${NC}%-24.24s ${B}│${NC}\n" \
        "MGRE Core v${MODULE_VERSION}" "$s_ip" "$active_tunnels" ""
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    local TYPE REMOTE_PUB T_NAME CORE_SUBNET FWD_TCP FWD_UDP MAX_IPS TUN_SECRET pure_name vip_stat vip_col
    local live_ping live_loss cached_entry loss_disp loss_col fwd_str tun_uptime stat_icon stat_col fwd_col sec_disp
    local len_name len_rem pad_peer sp_peer
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; T_NAME=""; CORE_SUBNET=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; TUN_SECRET=""; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        ((shown++))
        [ "$shown" -gt 3 ] && break

        pure_name=$(get_pure_tun_name "$T_NAME")
        pure_name="${pure_name:0:10}"
        REMOTE_PUB="${REMOTE_PUB:0:18}"

        len_name=${#pure_name}
        len_rem=${#REMOTE_PUB}
        pad_peer=$(( 38 - (len_name + len_rem) ))
        [ "$pad_peer" -lt 0 ] && pad_peer=0
        sp_peer=$(printf '%*s' "$pad_peer" "")

        vip_stat="OFF"; vip_col="${DIM}"
        if [ -n "$MAX_IPS" ] && [ "$MAX_IPS" -gt 0 ] 2>/dev/null; then
            vip_stat="+${MAX_IPS}"
            vip_col="${G}"
        fi
        vip_stat="${vip_stat:0:5}"

        live_ping="---"; live_loss=""
        if [ -f "$SECURE_TMP/.mgre_stats_cache" ]; then
            cached_entry=$(grep "^${T_NAME}|" "$SECURE_TMP/.mgre_stats_cache" 2>/dev/null | head -n1)
            if [ -n "$cached_entry" ]; then
                live_ping=$(echo "$cached_entry" | cut -d'|' -f2)
                live_loss=$(echo "$cached_entry" | cut -d'|' -f3)
            fi
        fi
        live_ping="${live_ping:0:4}"

        loss_disp="---"; loss_col="${DIM}"
        if [ "$live_loss" != "---" ] && [ -n "$live_loss" ]; then
            loss_disp="${live_loss}%"
            if [ "$live_loss" -eq 0 ] 2>/dev/null; then loss_col="${G}"
            elif [ "$live_loss" -lt 30 ] 2>/dev/null; then loss_col="${Y}"
            else loss_col="${R}"; fi
        fi
        loss_disp="${loss_disp:0:4}"

        fwd_str="OFF"
        if [ "$TYPE" == "1" ]; then
            if [ -n "$FWD_TCP" ] && [ -n "$FWD_UDP" ]; then fwd_str="T+U"
            elif [ -n "$FWD_TCP" ]; then fwd_str="T:${FWD_TCP:0:2}"
            elif [ -n "$FWD_UDP" ]; then fwd_str="U:${FWD_UDP:0:2}"
            fi
        else
            fwd_str="GW"
        fi
        fwd_str="${fwd_str:0:5}"

        tun_uptime=$(get_iface_uptime "$T_NAME")
        stat_icon="●"; stat_col="${G}"
        if [ "$tun_uptime" == "DOWN" ]; then stat_icon="○"; stat_col="${R}"; fi
        tun_uptime="${tun_uptime:0:6}"

        fwd_col="${DIM}"; [ "$fwd_str" != "OFF" ] && fwd_col="${C}"

        sec_disp="${TUN_SECRET:0:5}"
        [ -z "$sec_disp" ] && sec_disp="---"
        sec_disp="${sec_disp:0:5}"

        printf "  ${B}│${NC} %b%s%b ${W}%s${NC} ${DIM}➔${NC} ${Y}%s${NC}%s ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-4.4s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6.6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Sec:${NC}${M}%-5.5s${NC} ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure_name" "$REMOTE_PUB" "$sp_peer" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$tun_uptime" "$fwd_col" "$fwd_str" "$NC" "$sec_disp"
    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-111.111s${NC}  ${B}│${NC}\n" "No active tunnels configured on this host."
    fi
    echo -e "  ${B}╰${border}╯${NC}"
}

self_update_module() {
    local rel_path="tunnels/mgre.sh"
    local cb="?t=$(date +%s)"
    
    local gh_ver="Unknown" mirror_ver="Unknown"
    [ -f "$SECURE_TMP/.mgre_remote_ver_github" ] && gh_ver=$(tr -d '\r\n ' < "$SECURE_TMP/.mgre_remote_ver_github")
    [ -f "$SECURE_TMP/.mgre_remote_ver_mirror" ] && mirror_ver=$(tr -d '\r\n ' < "$SECURE_TMP/.mgre_remote_ver_mirror")

    local gh_text="${C}Official GitHub Server${NC}"
    local mirror_text="${G}ParsPack Iranian Mirror${NC}"
    if [ "$gh_ver" != "Unknown" ]; then
        if [ "$gh_ver" != "$MODULE_VERSION" ]; then gh_text+="    ${Y}(v${MODULE_VERSION} ➔ v${gh_ver})${NC}"
        else gh_text+="    ${DIM}(v${gh_ver})${NC}"; fi
    else gh_text+="    ${DIM}(version unavailable)${NC}"; fi
    if [ "$mirror_ver" != "Unknown" ]; then
        if [ "$mirror_ver" != "$MODULE_VERSION" ]; then mirror_text+="    ${Y}(v${MODULE_VERSION} ➔ v${mirror_ver})${NC}"
        else mirror_text+="    ${DIM}(v${mirror_ver})${NC}"; fi
    else mirror_text+="    ${DIM}(version unavailable)${NC}"; fi

    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ OTA UPDATE SOURCE (MGRE Engine) ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ AUTOMATIC MIRRORS ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${gh_text}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${mirror_text} ${DIM}(c107328.parspack.net)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ MANUAL OVERRIDES ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Custom Personal Link${NC} ${DIM}(Direct .sh URL)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${M}Manual Code Paste${NC} ${DIM}(Offline Editor)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}\n"
    echo -ne "  ${C}Select Source ❯❯ ${NC}"; read -r src_opt
    
    local tmp_file="$SECURE_TMP/.mgre_update.$$"
    > "$tmp_file"

    if [[ "$src_opt" == "4" ]]; then
        if command -v nano >/dev/null 2>&1; then
            echo -e "  ${DIM}● Opening Nano editor... Paste code, press Ctrl+O, Enter, then Ctrl+X to save.${NC}"
            sleep 2; nano "$tmp_file"
        elif command -v vi >/dev/null 2>&1; then
            vi "$tmp_file"
        else
            echo -e "  ${R}✖ No text editor (nano/vi) found!${NC}"; rm -f "$tmp_file"; sleep 2; return
        fi
    elif [[ "$src_opt" =~ ^[123]$ ]]; then
        local dl_url=""
        case $src_opt in
            1) dl_url="https://raw.githubusercontent.com/htzserv/MTunnel/main/$rel_path$cb" ;;
            2) dl_url="https://c107328.parspack.net/c107328/MTunnel/$rel_path$cb" ;;
            3) echo -ne "  ${C}●${NC} ${W}Enter Direct Link: ${NC}"; read -r custom_url; dl_url=$(echo "$custom_url" | tr -d '\r ') ;;
        esac
        [ -z "$dl_url" ] && rm -f "$tmp_file" && return
        
        echo -e "\n  ${C}⟳${NC} ${W}Downloading Update...${NC}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp_file" "$dl_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 -O "$tmp_file" "$dl_url" 2>/dev/null
        fi
    else
        rm -f "$tmp_file"
        return
    fi

    sed -i 's/\r$//' "$tmp_file" 2>/dev/null
    if [ -s "$tmp_file" ] && head -n1 "$tmp_file" | grep -q "^#!/bin/bash" && bash -n "$tmp_file" 2>/dev/null; then
        local new_ver
        new_ver=$(grep -m1 '^MODULE_VERSION=' "$tmp_file" | cut -d'"' -f2)
        [ -z "$new_ver" ] && new_ver="Unknown"
        
        echo -e "\n  ${DIM}┌─[ VERSION CHECK & CONFIRMATION ]${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Current Version :${NC} ${R}v${MODULE_VERSION}${NC}"
        echo -e "  ${DIM}├─${NC} ${W}Target Version  :${NC} ${G}v${new_ver}${NC}"
        echo -e "  ${DIM}└─${NC} ${C}Proceed with overwrite? (y/n): ${NC}\c"; read -r confirm
        
        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            sed -i 's/\r$//' "$tmp_file" 2>/dev/null
            chmod +x "$tmp_file"
            
            cat "$tmp_file" > "$INSTALL_PATH" 2>/dev/null || true
            [ -f "$0" ] && cat "$tmp_file" > "$0" 2>/dev/null || true
            cp -f "$tmp_file" "$LOCAL_DIR/$rel_path" 2>/dev/null
            
            rm -f "$tmp_file"
            echo -e "  ${G}✔ Update successfully applied! Rebooting module...${NC}"
            sleep 1.5
            
            kill "$WATCHER_PID" "$PING_WATCHER_PID" 2>/dev/null
            exec "$INSTALL_PATH" "$@"
        else
            echo -e "  ${Y}● Update cancelled.${NC}"
            rm -f "$tmp_file"; sleep 1.5
        fi
    else
        echo -e "  ${R}✖ Update failed. Invalid format or network error.${NC}"
        rm -f "$tmp_file"; sleep 2
    fi
}

merge_ports() {
    local current="$1"; local add="$2"
    local -a result=(); local IFS=','
    local -a cur_arr=($current); local -a add_arr=($add)
    local p e found out=""
    for p in "${cur_arr[@]}"; do [ -n "$p" ] && result+=("$p"); done
    for p in "${add_arr[@]}"; do
        [ -z "$p" ] && continue
        found=0
        for e in "${result[@]}"; do [ "$e" == "$p" ] && found=1 && break; done
        [ "$found" -eq 0 ] && result+=("$p")
    done
    for p in "${result[@]}"; do out+="${p},"; done
    echo "${out%,}"
}

remove_ports() {
    local current="$1"; local rem="$2"
    [ -z "$rem" ] && { echo "$current"; return; }
    local IFS=','
    local -a cur_arr=($current); local -a rem_arr=($rem)
    local out="" p r skip
    for p in "${cur_arr[@]}"; do
        [ -z "$p" ] && continue
        skip=0
        for r in "${rem_arr[@]}"; do [ "$p" == "$r" ] && skip=1 && break; done
        [ "$skip" -eq 0 ] && out+="${p},"
    done
    echo "${out%,}"
}

apply_tunnel() {
    local conf="$1"
    [ ! -s "$conf" ] && return
    local TYPE="" LOCAL_PUB="" REMOTE_PUB="" MAX_IPS="0" SYNC_KEY="" TUN_SECRET="" T_NAME="" TUN_ID="" CORE_SUBNET="" TUN_PROTO="ipv4" LOCAL_IP6="" REMOTE_IP6="" FWD_TCP="" FWD_UDP="" LB_MODE="0" CUSTOM_MTU="" ENCRYPT="0"
    source "$conf" 2>/dev/null
    [ -z "$T_NAME" ] && return

    local c_sub="${CORE_SUBNET}"
    local local_tun=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")

    clean_mss_rules "$T_NAME"
    clean_fwd_rules "$T_NAME"
    xfrm_clear "$T_NAME"
    ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1

    local min_mtu max_mtu def_mtu
    read -r min_mtu max_mtu def_mtu <<< "$(mgre_mtu_limits "$TUN_PROTO")"
    local eff_mtu="$CUSTOM_MTU"
    if ! is_uint "$eff_mtu"; then
        eff_mtu="$def_mtu"; [ "$ENCRYPT" == "1" ] && eff_mtu=$((def_mtu - 64))
    fi
    [ "$eff_mtu" -lt "$min_mtu" ] && eff_mtu="$min_mtu"
    [ "$eff_mtu" -gt "$max_mtu" ] && eff_mtu="$max_mtu"
    local mss_val=$((eff_mtu - 40))

    if [[ "$TUN_PROTO" == "6to4" ]]; then
        ip tunnel add "sit_$T_NAME" mode sit remote "$REMOTE_PUB" local "$LOCAL_PUB" 2>/dev/null
        ip link set dev "sit_$T_NAME" mtu 1480 2>/dev/null; ip link set "sit_$T_NAME" up 2>/dev/null
        ip -6 addr add "$LOCAL_IP6/64" dev "sit_$T_NAME" 2>/dev/null
        ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" encaplimit none 2>/dev/null \
            || ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" 2>/dev/null
    else
        ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255 key "$TUN_ID" 2>/dev/null
    fi
    ip link set dev "$T_NAME" mtu "$eff_mtu" 2>/dev/null
    ip link set "$T_NAME" up 2>/dev/null
    ip addr add "$local_tun"/30 dev "$T_NAME" 2>/dev/null
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -m comment --comment "MGRE_MSS_$T_NAME" -j TCPMSS --set-mss "$mss_val" 2>/dev/null

    if [ "$ENCRYPT" == "1" ]; then
        if [[ "$TUN_PROTO" == "6to4" ]]; then xfrm_apply "$T_NAME" "$TYPE" "$LOCAL_PUB" "$REMOTE_PUB" "$TUN_SECRET" proto 41
        else xfrm_apply "$T_NAME" "$TYPE" "$LOCAL_PUB" "$REMOTE_PUB" "$TUN_SECRET" proto gre; fi
    fi

    if is_uint "$MAX_IPS" && [ "$MAX_IPS" -gt 0 ]; then
        local nip tip clash
        while read -r nip tip; do
            [ -z "$nip" ] && continue
            ip -4 addr show dev "$T_NAME" 2>/dev/null | grep -qF "inet $nip/" && continue
            clash=$(ip -4 route show match "$nip" 2>/dev/null | grep -v '^default' | grep -v "dev $T_NAME")
            if [ -n "$clash" ]; then echo "  [vIP] $nip skipped: overlaps existing route ($clash)" >&2; continue; fi
            ip addr add "$nip/30" dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null
        done < <(vip_targets "$SYNC_KEY" "$MAX_IPS" "$TYPE")
    fi

    mgre_apply_fwd "$conf"
    rebuild_guard
}

apply_all_tunnels() {
    local conf
    for conf in "$CONF_DIR"/*.conf; do 
        [ -f "$conf" ] && apply_tunnel "$conf"
    done
}

select_tunnel_interactive() {
    draw_mgre_header
    local configs=("$CONF_DIR"/*.conf)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return 1; }

    if [ ${#configs[@]} -eq 1 ]; then
        SELECTED_CONF="${configs[0]}"
        return 0
    fi

    echo -e "\n  ${B}╭───────────────── Select Target Tunnel ────────────────────╮${NC}"
    local i
    for i in "${!configs[@]}"; do
        printf "  ${B}│${NC}  ${Y}%-3.3s${NC} ${C}❯${NC} ${W}%-50.50s${NC}  ${B}│${NC}\n" "$((i+1))" "$(basename "${configs[$i]}" .conf)"
    done
    echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
    echo -ne "  ${C}●${NC} ${W}Select Tunnel [1-${#configs[@]}] or 'q': ${NC}"; read -r t_idx
    t_idx=$(echo "$t_idx" | tr -d '\r ')
    [[ "$t_idx" == "q" || -z "$t_idx" ]] && return 1

    local idx_zero
    if idx_zero=$(pick_index "$t_idx" "${#configs[@]}"); then
        SELECTED_CONF="${configs[$idx_zero]}"
        return 0
    fi
    echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1
    return 1
}

manage_port_forwarding() {
    local target_conf="$1"
    local TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 FWD_TCP FWD_UDP LB_MODE
    source "$target_conf" 2>/dev/null
    
    if [ "$TYPE" != "1" ]; then
        echo -e "\n  ${Y}● Port Forwarding & Load Balancer is only available on IRAN (Access) role!${NC}"
        sleep 2
        return
    fi

    local pf_opt add_tcp add_udp m_tcp m_udp rm_tcp rm_udp new_tcp new_udp new_lb
    while true; do
        draw_mgre_header
        echo -e "\n  ${DIM}┌─[ PORT FORWARDING MANAGER: ${W}${T_NAME}${DIM} ]${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Current TCP:${NC} ${Y}${FWD_TCP:-None}${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Current UDP:${NC} ${C}${FWD_UDP:-None}${NC}"
        echo -e "  ${DIM}│${NC} ${DIM}Load Balancer:${NC} $([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Add New Ports (Keep Existing)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Remove Specific Ports${NC}"
        echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${Y}Replace All Ports (Overwrite)${NC}"
        echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${C}Toggle Load Balancer (Distribute across vIPs)${NC}"
        echo -e "  ${DIM}│${NC}"
        echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Back${NC}\n"
        echo -ne "  ${C}Select ❯❯ ${NC}"; read -r pf_opt

        case $pf_opt in
            1)
                echo -ne "  ${C}●${NC} ${W}Add TCP Ports (e.g. 8080,9090 or 10000:10100) [Enter to skip]: ${NC}"; read -r add_tcp
                echo -ne "  ${C}●${NC} ${W}Add UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r add_udp
                add_tcp=$(sanitize_ports "$add_tcp" tcp)
                add_udp=$(sanitize_ports "$add_udp" udp)
                m_tcp=$(merge_ports "$FWD_TCP" "$add_tcp")
                m_udp=$(merge_ports "$FWD_UDP" "$add_udp")
                grep -v "^FWD_TCP=" "$target_conf" | grep -v "^FWD_UDP=" > "${target_conf}.tmp"
                echo "FWD_TCP=$m_tcp" >> "${target_conf}.tmp"
                echo "FWD_UDP=$m_udp" >> "${target_conf}.tmp"
                mv "${target_conf}.tmp" "$target_conf"
                FWD_TCP="$m_tcp"; FWD_UDP="$m_udp"
                apply_tunnel "$target_conf"
                echo -e "  ${G}● Ports added. TCP: ${FWD_TCP:-None} | UDP: ${FWD_UDP:-None}${NC}"; sleep 1.8
                ;;
            2)
                echo -ne "  ${C}●${NC} ${W}Remove TCP Ports (e.g. 8080,9090) [Enter to skip]: ${NC}"; read -r rm_tcp
                echo -ne "  ${C}●${NC} ${W}Remove UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r rm_udp
                rm_tcp=$(echo "$rm_tcp" | tr -dc '0-9,:')
                rm_udp=$(echo "$rm_udp" | tr -dc '0-9,:')
                m_tcp=$(remove_ports "$FWD_TCP" "$rm_tcp")
                m_udp=$(remove_ports "$FWD_UDP" "$rm_udp")
                grep -v "^FWD_TCP=" "$target_conf" | grep -v "^FWD_UDP=" > "${target_conf}.tmp"
                echo "FWD_TCP=$m_tcp" >> "${target_conf}.tmp"
                echo "FWD_UDP=$m_udp" >> "${target_conf}.tmp"
                mv "${target_conf}.tmp" "$target_conf"
                FWD_TCP="$m_tcp"; FWD_UDP="$m_udp"
                apply_tunnel "$target_conf"
                echo -e "  ${G}● Ports removed. TCP: ${FWD_TCP:-None} | UDP: ${FWD_UDP:-None}${NC}"; sleep 1.8
                ;;
            3)
                echo -ne "  ${C}●${NC} ${W}New TCP Ports (Current: ${Y}${FWD_TCP:-None}${W}): ${NC}"; read -r new_tcp
                echo -ne "  ${C}●${NC} ${W}New UDP Ports (Current: ${C}${FWD_UDP:-None}${W}): ${NC}"; read -r new_udp
                new_tcp=$(sanitize_ports "$new_tcp" tcp)
                new_udp=$(sanitize_ports "$new_udp" udp)
                grep -v "^FWD_TCP=" "$target_conf" | grep -v "^FWD_UDP=" > "${target_conf}.tmp"
                echo "FWD_TCP=$new_tcp" >> "${target_conf}.tmp"
                echo "FWD_UDP=$new_udp" >> "${target_conf}.tmp"
                mv "${target_conf}.tmp" "$target_conf"
                FWD_TCP="$new_tcp"; FWD_UDP="$new_udp"
                apply_tunnel "$target_conf"
                echo -e "  ${G}● Ports replaced. TCP: ${new_tcp:-None} | UDP: ${new_udp:-None}${NC}"; sleep 1.8
                ;;
            4)
                new_lb="1"; [ "$LB_MODE" == "1" ] && new_lb="0"
                set_conf_var "$target_conf" LB_MODE "$new_lb"
                LB_MODE="$new_lb"
                apply_tunnel "$target_conf"
                echo -e "  ${G}● Load Balancer set to $([ "$new_lb" == "1" ] && echo ON || echo OFF).${NC}"; sleep 1.5
                ;;
            0) break ;;
        esac
    done
}

show_mgre_monitor() {
    echo -e "\n  ${C}Live Monitoring (Auto-Refresh | Press 'q' to exit)${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 FWD_TCP FWD_UDP LB_MODE
    local v_ips title_color proto_lbl title_txt raw_l1 pad1 sp1 eval_l1 disp_tcp disp_udp lb_txt raw_l2 pad2 sp2 lb_stat eval_l2
    local c_sub main_tip main_lip ping_res lat lat_raw lat_color stat_icon stat_text stat_color m_icon total_v idx lip base_ip last tip v_icon

    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        
        title_color="${C}"; proto_lbl="IPv4"
        [[ "$TUN_PROTO" == "6to4" ]] && { title_color="${M}"; proto_lbl="IP6GRE"; }

        title_txt="${T_NAME} [${proto_lbl}]"
        raw_l1=" ▼ ${title_txt} | PUB: ${LOCAL_PUB} -> ${REMOTE_PUB}"
        pad1=$(( 92 - ${#raw_l1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${title_color}" "${title_txt}" "${NC}" "${LOCAL_PUB}" "${REMOTE_PUB}")
        
        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${eval_l1}${sp1}${B}│${NC}"
        
        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            disp_tcp="${FWD_TCP:-0}"; [ ${#disp_tcp} -gt 30 ] && disp_tcp="${disp_tcp:0:27}..."
            disp_udp="${FWD_UDP:-0}"; [ ${#disp_udp} -gt 30 ] && disp_udp="${disp_udp:0:27}..."
            lb_txt="OFF"; [ "$LB_MODE" == "1" ] && lb_txt="ON"
            raw_l2="   ↳ NAT: T:[${disp_tcp}] U:[${disp_udp}] LB:[${lb_txt}]"
            pad2=$(( 92 - ${#raw_l2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
            lb_stat=$([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")
            eval_l2="   ${DIM}↳ NAT:${NC} ${Y}T:[${disp_tcp}]${NC} ${C}U:[${disp_udp}]${NC} ${DIM}LB:[${lb_stat}${DIM}]${NC}"
            echo -e "  ${B}│${NC}${eval_l2}${sp2}${B}│${NC}"
        fi

        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-12.12s${NC} ${B}│${NC} ${DIM}%-12.12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        c_sub="${CORE_SUBNET}"
        main_tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        main_lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        
        ping_res=$(timeout 2 ping -c 1 -W 1 "$main_tip" 2>/dev/null)
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
            lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
        
        m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        main_lip="${main_lip:0:18}"; main_tip="${main_tip:0:18}"
        printf "  ${B}│${NC} ${W}%s %-15.15s${NC} ${B}│${NC} ${W}%-18.18s${NC} ${B}│${NC} ${W}%-18.18s${NC} ${B}│${NC} %b%-12.12s%b ${B}│${NC} %b%s %-10.10s%b ${B}│${NC}\n" "${m_icon}" "Core IP" "$main_lip" "$main_tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        
        total_v=${#v_ips[@]}
        for ((idx=0; idx<total_v; idx++)); do
            lip="${v_ips[$idx]}"; base_ip=$(echo "$lip" | cut -d'.' -f1-3); last=$(echo "$lip" | cut -d'.' -f4); tip="$base_ip.$([ "$last" == "1" ] && echo "2" || echo "1")"
            ping_res=$(timeout 2 ping -c 1 -W 1 "$tip" 2>/dev/null)
            if echo "$ping_res" | grep -q "time="; then
                lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
                lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
                lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
            else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi
            v_icon="│  ├─"; [ $idx -eq $((total_v - 1)) ] && v_icon="│  └─"
            lip="${lip:0:18}"; tip="${tip:0:18}"
            printf "  ${B}│${NC} ${DIM}%s %-12.12s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} %b%-12.12s%b ${B}│${NC} %b%s %-10.10s%b ${B}│${NC}\n" "${v_icon}" "vIP" "$lip" "$tip" "$lat_color" "$lat_raw" "$NC" "$stat_color" "$stat_icon" "$stat_text" "$NC"
        done
        echo -e "  ${B}╰────────────────────┴────────────────────┴────────────────────┴──────────────┴──────────────╯${NC}\n"
    done
}

show_tunnel_details() {
    draw_mgre_header
    local configs=("$CONF_DIR"/*.conf)
    [ ! -e "${configs[0]}" ] && { echo -e "\n  ${R}● No tunnels configured yet!${NC}"; sleep 1.5; return; }

    echo -e "\n  ${Y}● Deployed Tunnels Registry:${NC}"
    local conf TYPE LOCAL_PUB REMOTE_PUB MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET TUN_PROTO LOCAL_IP6 REMOTE_IP6 FWD_TCP FWD_UDP LB_MODE CUSTOM_MTU
    local c_sub lip tip t_role t_sec t_id proto_lbl lb_txt left_p right_p pad sp l1 r1 pad1 sp1 l2 r2 pad2 sp2 l3 r3 pad3 sp3 l4 pad4 sp4 l5 r5 pad5 sp5
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; CUSTOM_MTU=""; source "$conf" 2>/dev/null
        c_sub="${CORE_SUBNET}"
        lip=$([ "$TYPE" == "1" ] && echo "${c_sub}.1" || echo "${c_sub}.2")
        tip=$([ "$TYPE" == "1" ] && echo "${c_sub}.2" || echo "${c_sub}.1")
        t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        t_sec="${TUN_SECRET:-[ NOT SET ]}"
        t_id="${TUN_ID:-[ NOT SET ]}"

        local act_mtu=""
        [ -d "/sys/class/net/$T_NAME" ] && act_mtu=$(cat "/sys/class/net/$T_NAME/mtu" 2>/dev/null)
        local def_mtu; def_mtu=$(mgre_mtu_limits "$TUN_PROTO" | awk '{print $3}')
        local curr_mtu="${act_mtu:-${CUSTOM_MTU:-$def_mtu (Auto)}}"

        proto_lbl="IPv4 GRE"; [[ "$TUN_PROTO" == "6to4" ]] && proto_lbl="6to4 IP6GRE"

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        left_p="▼ Tunnel: ${T_NAME:0:25}"; right_p="Role: $t_role"
        pad=$(( 90 - ${#left_p} - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"
        
        l1="Master Token : ${t_sec:0:25}"; r1="Protocol: ${proto_lbl}"
        pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Master Token :${NC} ${W}${t_sec:0:25}${NC}${sp1}${DIM}Protocol:${NC} ${W}${proto_lbl}${NC} ${B}│${NC}"
        
        local sync_disp="${SYNC_KEY:-Same As Token}"; sync_disp="${sync_disp:0:25}"
        l2="vIP Sync Key : ${sync_disp}"; r2="Network Key ID: ${t_id:0:15}"
        pad2=$(( 90 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}vIP Sync Key :${NC} ${W}${sync_disp}${NC}${sp2}${DIM}Network Key ID:${NC} ${Y}${t_id:0:15}${NC} ${B}│${NC}"
        
        l3="Public IPs   : ${LOCAL_PUB:0:16} -> ${REMOTE_PUB:0:16}"; r3="MTU: ${curr_mtu}"
        pad3=$(( 90 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
        echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${LOCAL_PUB:0:16}${NC} ${DIM}->${NC} ${W}${REMOTE_PUB:0:16}${NC}${sp3}${DIM}MTU:${NC} ${G}${curr_mtu}${NC} ${B}│${NC}"

        l4="Core Subnet  : ${c_sub}.x (${lip} -> ${tip})"
        pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
        echo -e "  ${B}│${NC} ${DIM}Core Subnet  :${NC} ${G}${c_sub}.x${NC} ${DIM}(${lip} -> ${tip})${NC}${sp4} ${B}│${NC}"
        
        if [ "$TYPE" == "1" ]; then
            lb_txt=$([ "$LB_MODE" == "1" ] && echo "Active (All vIPs)" || echo "Direct (Core IP)")
            local fwd_disp="${FWD_TCP:-None}"; [ ${#fwd_disp} -gt 25 ] && fwd_disp="${fwd_disp:0:22}..."
            l5="NAT FWD TCP  : ${fwd_disp}"; r5="Load Balancer: ${lb_txt}"
            pad5=$(( 90 - ${#l5} - ${#r5} )); [ "$pad5" -lt 0 ] && pad5=0; sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${Y}NAT FWD TCP  :${NC} ${W}${fwd_disp}${NC}${sp5}${C}Load Balancer:${NC} ${W}${lb_txt}${NC} ${B}│${NC}"
        fi
        
        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
}

uninstall_mgre() {
    draw_mgre_header
    echo -e "\n  ${R}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${R}│${NC}   ${R}⚠ WARNING: COMPLETE PURGE & UNINSTALLATION OF MGRE${NC}                      ${R}│${NC}"
    echo -e "  ${R}│${NC}   This will permanently stop and delete:                                   ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All active GRE/IP6GRE tunnel interfaces and IP aliases                  ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All configurations & metadata in /etc/mgre/tunnels                     ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● All iptables NAT, FORWARD, MSS clamping and Load Balancer rules         ${R}│${NC}"
    echo -e "  ${R}│${NC}   ● MGRE systemd service & executable wrapper                               ${R}│${NC}"
    echo -e "  ${R}╰────────────────────────────────────────────────────────────────────────────╯${NC}\n"
    
    local confirm conf T_NAME
    echo -ne "  ${Y}Are you sure you want to proceed? Type '${R}yes${Y}' to confirm: ${NC}"; read -r confirm
    confirm=$(echo "$confirm" | tr -d '\r ')
    
    if [ "$confirm" != "yes" ]; then
        echo -e "  ${G}● Uninstallation cancelled.${NC}"; sleep 1.5; return
    fi

    echo -e "\n  ${DIM}● [1/4] Stopping services and removing tunnel interfaces...${NC}"
    systemctl stop mgre.service 2>/dev/null
    systemctl disable mgre.service 2>/dev/null

    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        teardown_tunnel "$conf"
    done
    watchdog_disable
    rm -f "$GUARD_FLAG"; rebuild_guard

    echo -e "  ${DIM}● [2/4] Removing systemd unit files...${NC}"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null

    echo -e "  ${DIM}● [3/4] Deleting configurations & temporary files...${NC}"
    rm -rf "$CONF_DIR" "$SECURE_TMP/.mgre"* "$WD_LOG"

    echo -e "  ${DIM}● [4/4] Removing mgre executable script...${NC}"
    rm -f "$INSTALL_PATH" 2>/dev/null
    [ -f "$0" ] && rm -f "$0" 2>/dev/null

    echo -e "\n  ${G}✔ MGRE ecosystem has been completely eradicated.${NC}\n"
    exit 0
}

setup_service() {
    local tmp_srv="$SECURE_TMP/mgre_tpl.service"
    cat <<EOF > "$tmp_srv"
[Unit]
Description=MGRE Native Edge Service
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/bin/mgre --apply
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$tmp_srv" "$SERVICE_FILE" 2>/dev/null; then
        mv -f "$tmp_srv" "$SERVICE_FILE"
        systemctl daemon-reload && systemctl enable mgre.service >/dev/null 2>&1
    else
        rm -f "$tmp_srv"
    fi
}


# ======================================================================
# [ v-next ] MGRE specific engine pieces
# ======================================================================
clean_fwd_rules() {
    local t="$1"; [ -z "$t" ] && return
    ipt_delete_tagged nat PREROUTING "MGRE_FWD_${t}"
    ipt_delete_tagged nat POSTROUTING "MGRE_FWD_${t}"
    ipt_delete_tagged filter FORWARD "MGRE_FWD_${t}"
}
clean_mss_rules() {
    local t="$1"; [ -z "$t" ] && return
    ipt_delete_tagged mangle FORWARD "MGRE_MSS_${t}"
}

mgre_mtu_limits() { # <proto> -> "min max default"
    if [ "$1" == "6to4" ]; then echo "1280 1432 1420"; else echo "700 1472 1436"; fi
}

mgre_apply_fwd() {
    local conf="$1"
    local TYPE="" T_NAME="" CORE_SUBNET="" MAX_IPS="0" SYNC_KEY="" FWD_TCP="" FWD_UDP="" LB_MODE="0"
    source "$conf" 2>/dev/null
    clean_fwd_rules "$T_NAME"
    [ "$TYPE" == "1" ] || return 0
    [ -n "$FWD_TCP" ] && FWD_TCP=$(sanitize_ports "$FWD_TCP" tcp 2>/dev/null)
    [ -z "$FWD_TCP" ] && [ -z "$FWD_UDP" ] && return 0
    local -a targets=("${CORE_SUBNET}.2")
    local pair
    while read -r pair; do [ -n "$pair" ] && targets+=("${pair#* }"); done < <(vip_targets "$SYNC_KEY" "$MAX_IPS" "$TYPE")
    build_fwd_rules "MGRE_FWD_$T_NAME" "$T_NAME" "$FWD_TCP" "$FWD_UDP" "$LB_MODE" "$SECURE_TMP/.mgre_lbdead_${T_NAME}" "${targets[@]}"
}

teardown_tunnel() {
    local conf="$1" T_NAME=""
    source "$conf" 2>/dev/null
    [ -z "$T_NAME" ] && return
    clean_fwd_rules "$T_NAME"; clean_mss_rules "$T_NAME"; xfrm_clear "$T_NAME"
    ip tunnel del "$T_NAME" >/dev/null 2>&1; ip tunnel del "sit_$T_NAME" >/dev/null 2>&1
    rm -f "$SECURE_TMP/.mgre_lbdead_${T_NAME}"
}

rebuild_guard() {
    ipt_delete_tagged filter INPUT "MGRE_GUARD_HOOK"
    iptables -F MGRE_GUARD 2>/dev/null
    if [ ! -f "$GUARD_FLAG" ]; then iptables -X MGRE_GUARD 2>/dev/null; return 0; fi
    iptables -N MGRE_GUARD 2>/dev/null
    local conf REMOTE_PUB
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        REMOTE_PUB=""; source "$conf" 2>/dev/null
        is_ipv4 "$REMOTE_PUB" && iptables -A MGRE_GUARD -s "$REMOTE_PUB" -j ACCEPT
    done
    iptables -A MGRE_GUARD -j DROP
    iptables -I INPUT 1 -p gre -m comment --comment "MGRE_GUARD_HOOK" -j MGRE_GUARD
    iptables -I INPUT 1 -p 41  -m comment --comment "MGRE_GUARD_HOOK" -j MGRE_GUARD
}

mgre_watchdog() {
    local conf TYPE T_NAME CORE_SUBNET MAX_IPS SYNC_KEY LB_MODE FWD_TCP FWD_UDP tip pair t deadf newdead
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; CORE_SUBNET=""; MAX_IPS="0"; SYNC_KEY=""; LB_MODE="0"; FWD_TCP=""; FWD_UDP=""
        source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        tip=$([ "$TYPE" == "1" ] && echo "${CORE_SUBNET}.2" || echo "${CORE_SUBNET}.1")
        if [ ! -d "/sys/class/net/$T_NAME" ]; then
            wd_log "$T_NAME: interface missing, re-applying"; apply_tunnel "$conf"; continue
        fi
        local failf="$SECURE_TMP/.mgre_wdfail_${T_NAME}" fails
        if ! ping -c 3 -i 0.3 -W 2 "$tip" >/dev/null 2>&1; then
            fails=$(( $(cat "$failf" 2>/dev/null || echo 0) + 1 )); echo "$fails" > "$failf"
            if [ "$fails" -ge 2 ]; then
                wd_log "$T_NAME: peer $tip unreachable ${fails}x, re-applying tunnel"; apply_tunnel "$conf"; echo 0 > "$failf"
            fi
            continue
        fi
        echo 0 > "$failf"
        if [ "$TYPE" == "1" ] && [ "$LB_MODE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            deadf="$SECURE_TMP/.mgre_lbdead_${T_NAME}"; newdead=""
            while read -r pair; do
                [ -z "$pair" ] && continue; t="${pair#* }"
                ping -c 2 -i 0.3 -W 1 "$t" >/dev/null 2>&1 || newdead+="$t"$'\n'
            done < <(vip_targets "$SYNC_KEY" "$MAX_IPS" "$TYPE")
            if [ "$(printf '%s' "$newdead")" != "$(cat "$deadf" 2>/dev/null)" ]; then
                printf '%s' "$newdead" > "$deadf"
                wd_log "$T_NAME: LB pool changed, dead vIPs: $(echo "$newdead" | tr '\n' ' ')"
                mgre_apply_fwd "$conf"
            fi
        fi
    done
}

mgre_status_cli() {
    local conf TYPE T_NAME REMOTE_PUB CORE_SUBNET ENCRYPT tip st lat
    printf "%-16s %-16s %-6s %-8s %-8s %s\n" "TUNNEL" "PEER" "ROLE" "LINK" "PING" "ENC"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; REMOTE_PUB=""; CORE_SUBNET=""; ENCRYPT="0"; source "$conf" 2>/dev/null
        tip=$([ "$TYPE" == "1" ] && echo "${CORE_SUBNET}.2" || echo "${CORE_SUBNET}.1")
        st=$([ -d "/sys/class/net/$T_NAME" ] && echo UP || echo DOWN)
        lat=$(ping -c1 -W1 "$tip" 2>/dev/null | grep -oP 'time=\K[0-9.]+'); lat="${lat:+${lat}ms}"
        printf "%-16s %-16s %-6s %-8s %-8s %s\n" "$T_NAME" "$REMOTE_PUB" "$([ "$TYPE" == "1" ] && echo IR || echo KH)" "$st" "${lat:----}" "$([ "$ENCRYPT" == "1" ] && echo ON || echo OFF)"
    done
}

# ---------------- ADVANCED MENU ACTIONS ----------------
menu_encrypt() {
    select_tunnel_interactive || return
    local ENCRYPT="0" T_NAME="" TYPE="" LOCAL_PUB="" REMOTE_PUB="" TUN_SECRET=""; source "$SELECTED_CONF" 2>/dev/null
    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ IPsec ESP ENCRYPTION: ${W}${T_NAME}${DIM} ]${NC}"
    echo -e "  ${DIM}│${NC} Status : $([ "$ENCRYPT" == "1" ] && echo -e "${G}ENCRYPTED (AES-256-CBC + HMAC-SHA256)${NC}" || echo -e "${R}PLAINTEXT GRE${NC}")"
    echo -e "  ${DIM}│${NC} ${Y}Both peers MUST run the same mode with the same Master Token, or the link drops.${NC}"
    echo -e "  ${DIM}│${NC} ${DIM}Auto MTU shrinks by 64 bytes for ESP overhead.${NC}"
    echo -e "  ${DIM}└─${NC}"
    echo -ne "  ${C}●${NC} ${W}Turn encryption $([ "$ENCRYPT" == "1" ] && echo OFF || echo ON)? (y/n): ${NC}"; read -r ans
    [[ "${ans,,}" == "y" ]] || return
    local nv="1"; [ "$ENCRYPT" == "1" ] && nv="0"
    set_conf_var "$SELECTED_CONF" ENCRYPT "$nv"
    apply_tunnel "$SELECTED_CONF"
    if [ "$nv" == "1" ] && [ ! -f "$(xfrm_state_file "$T_NAME")" ]; then
        echo -e "  ${R}✖ Kernel rejected IPsec setup (missing xfrm/esp modules or local IP not on host). Reverted.${NC}"
        set_conf_var "$SELECTED_CONF" ENCRYPT 0; apply_tunnel "$SELECTED_CONF"; sleep 2.5; return
    fi
    echo -e "  ${G}✔ Encryption is now $([ "$nv" == "1" ] && echo ON || echo OFF). Do the same on the peer server.${NC}"; sleep 2
}

menu_guard() {
    draw_mgre_header
    local on=0; [ -f "$GUARD_FLAG" ] && on=1
    echo -e "\n  ${DIM}┌─[ FIREWALL GUARD (Anti-Spoof / Anti-Injection) ]${NC}"
    echo -e "  ${DIM}│${NC} Status : $([ "$on" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${R}OFF${NC}")"
    echo -e "  ${DIM}│${NC} Accepts GRE / proto-41 packets ONLY from configured peer IPs, drops the rest."
    echo -e "  ${DIM}│${NC} ${Y}Note: blocks any other GRE/6in4 tunnels on this host that are not managed by MGRE.${NC}"
    echo -e "  ${DIM}└─${NC}"
    echo -ne "  ${C}●${NC} ${W}Turn Guard $([ "$on" == "1" ] && echo OFF || echo ON)? (y/n): ${NC}"; read -r ans
    [[ "${ans,,}" == "y" ]] || return
    if [ "$on" == "1" ]; then rm -f "$GUARD_FLAG"; else mkdir -p "$MT_ROOT_CONF"; touch "$GUARD_FLAG"; fi
    rebuild_guard
    echo -e "  ${G}✔ Firewall Guard $([ "$on" == "1" ] && echo disabled || echo enabled).${NC}"; sleep 1.8
}

menu_watchdog() {
    draw_mgre_header
    local on=0; watchdog_is_on && on=1
    echo -e "\n  ${DIM}┌─[ WATCHDOG: AUTO-HEAL + LB HEALTH CHECK ]${NC}"
    echo -e "  ${DIM}│${NC} Status : $([ "$on" == "1" ] && echo -e "${G}ACTIVE (every 60s)${NC}" || echo -e "${R}OFF${NC}")"
    echo -e "  ${DIM}│${NC} ● Re-applies a tunnel if its interface vanishes or the peer stops answering."
    echo -e "  ${DIM}│${NC} ● With Load Balancer ON, dead vIPs are pulled out of rotation and re-added when back."
    echo -e "  ${DIM}│${NC} ● Log: ${W}${WD_LOG}${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} Toggle Watchdog   ${W}2${NC} ${DIM}❯${NC} Show last 20 log lines   ${W}0${NC} ${DIM}❯${NC} Back"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r ans
    case "$ans" in
        1) if [ "$on" == "1" ]; then watchdog_disable; echo -e "  ${Y}● Watchdog disabled.${NC}"; else watchdog_enable; echo -e "  ${G}✔ Watchdog enabled.${NC}"; fi; sleep 1.5 ;;
        2) echo ""; tail -n 20 "$WD_LOG" 2>/dev/null || echo "  (empty)"; echo -ne "\n  ${DIM}Press Enter...${NC}"; read -r _ ;;
    esac
}

menu_auto_mtu() {
    select_tunnel_interactive || return
    local T_NAME="" TUN_PROTO="ipv4" REMOTE_PUB="" ENCRYPT="0"; source "$SELECTED_CONF" 2>/dev/null
    draw_mgre_header
    echo -e "\n  ${C}⟳${NC} ${W}Probing path MTU to ${REMOTE_PUB} (DF-bit binary search)...${NC}"
    local pmtu; pmtu=$(probe_path_mtu "$REMOTE_PUB")
    if [ "$pmtu" -eq 0 ]; then echo -e "  ${R}✖ Peer does not answer ICMP. Cannot probe, set MTU manually (option 10).${NC}"; sleep 2.5; return; fi
    local ovh=28; [ "$TUN_PROTO" == "6to4" ] && ovh=68; [ "$ENCRYPT" == "1" ] && ovh=$((ovh + 64))
    local lim min max; lim=$(mgre_mtu_limits "$TUN_PROTO"); min=${lim%% *}; max=$(echo "$lim" | awk '{print $2}')
    local best=$((pmtu - ovh)); [ "$best" -gt "$max" ] && best=$max; [ "$best" -lt "$min" ] && best=$min
    echo -e "  ${DIM}├─${NC} Path MTU      : ${W}${pmtu}${NC}"
    echo -e "  ${DIM}├─${NC} Tunnel overhead: ${W}${ovh}${NC} bytes"
    echo -e "  ${DIM}└─${NC} Recommended   : ${G}${best}${NC} (MSS $((best - 40)))"
    echo -ne "  ${C}●${NC} ${W}Apply ${best} to ${T_NAME}? Use the same value on the peer. (y/n): ${NC}"; read -r ans
    [[ "${ans,,}" == "y" ]] || return
    set_conf_var "$SELECTED_CONF" CUSTOM_MTU "$best"
    apply_tunnel "$SELECTED_CONF"
    echo -e "  ${G}✔ MTU set to ${best}.${NC}"; sleep 1.8
}

show_traffic_monitor() {
    local -A prx ptx
    local conf T_NAME rx tx drx dtx first=1 k
    while true; do
        draw_mgre_header
        echo -e "\n  ${C}Live Traffic (1s refresh | 'q' to exit)${NC}\n"
        printf "  ${DIM}%-16s %-14s %-14s %-12s %-12s${NC}\n" "TUNNEL" "RX RATE" "TX RATE" "RX TOTAL" "TX TOTAL"
        for conf in "$CONF_DIR"/*.conf; do
            [ -f "$conf" ] || continue
            T_NAME=""; source "$conf" 2>/dev/null
            [ -d "/sys/class/net/$T_NAME" ] || { printf "  %-16s ${R}%s${NC}\n" "$T_NAME" "DOWN"; continue; }
            rx=$(cat "/sys/class/net/$T_NAME/statistics/rx_bytes"); tx=$(cat "/sys/class/net/$T_NAME/statistics/tx_bytes")
            drx=$(( rx - ${prx[$T_NAME]:-$rx} )); dtx=$(( tx - ${ptx[$T_NAME]:-$tx} ))
            prx[$T_NAME]=$rx; ptx[$T_NAME]=$tx
            printf "  ${W}%-16s${NC} ${G}%-14s${NC} ${Y}%-14s${NC} %-12s %-12s\n" "$T_NAME" "$(human_rate $drx)" "$(human_rate $dtx)" "$(human_bytes $rx)" "$(human_bytes $tx)"
        done
        read -t 1 -n 1 -s k; [[ "$k" == "q" || "$k" == "Q" ]] && break
    done
}

menu_backup_restore() {
    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ BACKUP & RESTORE ]${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Create Backup${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${Y}Restore From Backup${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} Back"
    echo -ne "  ${C}Select ❯❯ ${NC}"; read -r ans
    if [ "$ans" == "1" ]; then
        local f; f=$(backup_configs)
        [ -n "$f" ] && echo -e "  ${G}✔ Saved: ${f}${NC}" || echo -e "  ${R}✖ Backup failed.${NC}"; sleep 2
    elif [ "$ans" == "2" ]; then
        local -a bks=("$BACKUP_DIR"/mgre-*.tgz)
        [ -e "${bks[0]}" ] || { echo -e "  ${R}● No backups found.${NC}"; sleep 1.5; return; }
        local i; for i in "${!bks[@]}"; do echo -e "  ${Y}$((i+1))${NC} ❯ $(basename "${bks[$i]}")"; done
        echo -ne "  ${C}●${NC} ${W}Pick backup: ${NC}"; read -r sel
        local idx; idx=$(pick_index "$sel" "${#bks[@]}") || return
        echo -ne "  ${R}● Current tunnels will be replaced. Type 'yes': ${NC}"; read -r c; [ "$c" == "yes" ] || return
        local conf; for conf in "$CONF_DIR"/*.conf; do [ -f "$conf" ] && teardown_tunnel "$conf"; done
        backup_configs >/dev/null
        rm -f "$CONF_DIR"/*.conf
        tar xzf "${bks[$idx]}" -C "$(dirname "$CONF_DIR")" 2>/dev/null
        apply_all_tunnels
        echo -e "  ${G}✔ Restored and applied.${NC}"; sleep 2
    fi
}
# ======================================================================

case "$1" in
    --apply)    apply_all_tunnels; exit 0 ;;
    --watchdog) mgre_watchdog; exit 0 ;;
    --status|--list) mgre_status_cli; exit 0 ;;
    --backup)   f=$(backup_configs); [ -n "$f" ] && echo "Backup: $f" || { echo "Backup failed"; exit 1; }; exit 0 ;;
    --guard-on)  mkdir -p "$MT_ROOT_CONF"; touch "$GUARD_FLAG"; rebuild_guard; echo "Guard ON"; exit 0 ;;
    --guard-off) rm -f "$GUARD_FLAG"; rebuild_guard; echo "Guard OFF"; exit 0 ;;
    --help|-h)
        echo "mgre v$MODULE_VERSION"
        echo "  mgre                 interactive menu"
        echo "  mgre --apply         re-apply all tunnels (used by systemd)"
        echo "  mgre --status        print tunnel status table"
        echo "  mgre --watchdog      run one watchdog cycle"
        echo "  mgre --backup        backup configs to $BACKUP_DIR"
        echo "  mgre --guard-on|--guard-off   toggle firewall guard"
        exit 0 ;;
esac

[ ! -f "$SERVICE_FILE" ] && setup_service

render_mgre_menu() {
    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Tunnel (IPv4 / IP6GRE)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${G}Virtual IP Manager (Add/Purge vIPs)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${C}MPorter Port Forwarder / Manager${NC}"
    echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}Manage Port Forwarding & Load Balancer${NC}"
    echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${M}View Tunnel Config Registry${NC}"
    echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${R}Delete Tunnels (Specific / ALL)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ CONFIGURATION ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}7${NC} ${DIM}❯${NC} ${W}Edit Tunnel Name${NC}"
    echo -e "  ${DIM}├─${NC} ${W}8${NC} ${DIM}❯${NC} ${C}Edit Public IPs (Local / Remote)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}9${NC} ${DIM}❯${NC} ${M}Edit Master Token & Secret Key${NC}"
    echo -e "  ${DIM}├─${NC} ${W}10${NC}${DIM}❯${NC} ${Y}Edit Core Subnet Base${NC}"
    echo -e "  ${DIM}├─${NC} ${W}11${NC}${DIM}❯${NC} ${C}Edit MTU & MSS${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}12${NC}${DIM}❯${NC} ${W}Live Monitoring (Auto-Refresh Radar)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}13${NC}${DIM}❯${NC} ${Y}Live Traffic Monitor (RX/TX Rate)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}14${NC}${DIM}❯${NC} ${C}Auto MTU Discovery (Path Probe)${NC}"
    echo -e "  ${DIM}├─${NC} ${W}15${NC}${DIM}❯${NC} ${M}IPsec Encryption (ESP) per Tunnel${NC}"
    echo -e "  ${DIM}├─${NC} ${W}16${NC}${DIM}❯${NC} ${R}Firewall Guard (Peer-Only GRE)${NC} $([ -f "$GUARD_FLAG" ] && echo -e "${G}[ON]${NC}" || echo -e "${DIM}[OFF]${NC}")"
    echo -e "  ${DIM}├─${NC} ${W}17${NC}${DIM}❯${NC} ${G}Watchdog: Auto-Heal + LB Health${NC} $(watchdog_is_on && echo -e "${G}[ON]${NC}" || echo -e "${DIM}[OFF]${NC}")"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─[ SYSTEM ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}18${NC}${DIM}❯${NC} ${W}Backup & Restore Configs${NC}"
    echo -e "  ${DIM}├─${NC} ${W}19${NC}${DIM}❯${NC} ${G}Instant OTA Update Module${NC}"
    echo -e "  ${DIM}├─${NC} ${W}20${NC}${DIM}❯${NC} ${R}Uninstall MGRE${NC} ${DIM}(Purge All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mgre_menu
    read_with_refresh "  ${C}MGRE ❯❯ ${NC}" opt render_mgre_menu
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           draw_mgre_header
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}"
           echo -e "  ${DIM}│${NC}"
           echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Standard IPv4 GRE${NC}"
           echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}6to4 IP6GRE Encapsulation${NC}"
           echo -e "  ${DIM}│${NC}"
           echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}\n"
           while true; do echo -ne "  ${C}Select Protocol ❯❯ ${NC}"; read -r proto_choice; [[ "$proto_choice" == "q" ]] && break; [[ "$proto_choice" == "1" || "$proto_choice" == "2" ]] && break; done
           [[ "$proto_choice" == "q" ]] && continue
           tun_proto="ipv4"; [ "$proto_choice" == "2" ] && tun_proto="6to4"
           
           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read -r s_type; [[ "$s_type" == "q" ]] && break; [[ "$s_type" == "1" || "$s_type" == "2" ]] && break; done
           [[ "$s_type" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4-5 chars): ${NC}"; read -r suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break; [[ -z "$suffix" ]] && continue
               pfx=$([ "$tun_proto" == "6to4" ] && echo "$([ "$s_type" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$s_type" == "1" ] && echo "greir" || echo "grekh")")
               t_name="${pfx}${suffix}"
               check_len=${#t_name}; [ "$tun_proto" == "6to4" ] && check_len=$((check_len + 4))
               if [ "$check_len" -gt 15 ]; then echo -e "  ${R}● Error: Name too long! Kernel limit is 15 chars.${NC}"; else break; fi
           done
           [[ "$suffix" == "q" ]] && continue
           
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then echo -e "\n  ${R}● Error: Interface name [${t_name}] already exists!${NC}"; sleep 2; continue; fi
           
           local_ip=$(get_local_ip)
           while true; do
               echo -ne "  ${C}●${NC} ${W}Local Public IP [${Y}${local_ip}${W}]: ${NC}"; read -r custom_ip
               [[ "$custom_ip" == "q" ]] && break
               custom_ip=$(echo "$custom_ip" | tr -dc '0-9.')
               if [ -n "$custom_ip" ] && ! is_ipv4 "$custom_ip"; then echo -e "  ${R}✖ Invalid IPv4 address.${NC}"; continue; fi
               [ -n "$custom_ip" ] && local_ip=$custom_ip
               break
           done
           [[ "$custom_ip" == "q" ]] && continue
           
           while true; do
               echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IP: ${NC}"; read -r r_ip
               [[ "$r_ip" == "q" ]] && break
               r_ip=$(echo "$r_ip" | tr -dc '0-9.'); is_ipv4 "$r_ip" && break
               echo -e "  ${R}✖ Invalid IPv4 address.${NC}"
           done
           [[ "$r_ip" == "q" ]] && continue

           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null)
           [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}●${NC} ${M}Master Secret Token [Default ${s_key}]: ${NC}"; read -r u_key
           [[ "$u_key" == "q" ]] && continue
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-')
           tun_secret=${u_key:-$s_key}

           # Set a path-aware MTU silently during setup; the MTU menu remains available for manual changes.
           read -r min_mtu max_mtu def_mtu <<< "$(mgre_mtu_limits "$tun_proto")"
           echo -e "  ${C}⟳${NC} ${W}Detecting a safe tunnel MTU automatically...${NC}"
           cust_mtu=$(auto_mtu_for_gre "$r_ip" "$tun_proto")

           local_ip6=""; remote_ip6=""
           if [[ "$tun_proto" == "6to4" ]]; then
               hash_str=$(echo -n "${tun_secret}_MHDesign" | sha256sum)
               pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
               if [[ "$s_type" == "1" ]]; then local_ip6="${pfx_v6}::1"; remote_ip6="${pfx_v6}::2"; else local_ip6="${pfx_v6}::2"; remote_ip6="${pfx_v6}::1"; fi
           fi
           
           hash_c=$(echo -n "core_${tun_secret}" | sha256sum)
           tun_id=$(( 16#${hash_c:0:6} ))
           
           class_selector=$(( 16#${hash_c:6:2} % 3 ))
           c1=""; c2=""; c3=""
           if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
           else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
           
           core_sub="${c1}.${c2}.${c3}"
           
           if grep -q "^TUN_ID=$tun_id$" "$CONF_DIR"/*.conf 2>/dev/null || subnet_in_use "$core_sub"; then
               echo -e "  ${R}● Collision: subnet ${core_sub}.x or key already used (MGRE/MXLAN/system route). Choose a different Token.${NC}"; sleep 2.5; continue
           fi
           
           conf_path="$CONF_DIR/${t_name}.conf"
           echo -e "TYPE=$s_type\nLOCAL_PUB=$local_ip\nREMOTE_PUB=$r_ip\nMAX_IPS=0\nSYNC_KEY=\nTUN_SECRET=$tun_secret\nT_NAME=$t_name\nTUN_ID=$tun_id\nCORE_SUBNET=$core_sub\nTUN_PROTO=$tun_proto\nLOCAL_IP6=$local_ip6\nREMOTE_IP6=$remote_ip6\nFWD_TCP=\nFWD_UDP=\nLB_MODE=0\nCUSTOM_MTU=$cust_mtu" > "$conf_path"
           chmod 600 "$conf_path"
           apply_tunnel "$conf_path"
           
           if ip link show "$t_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Tunnel [${t_name}] deployed successfully (Subnet: ${core_sub}.x | Auto MTU: ${cust_mtu})${NC}"
               remote_tip=$([ "$s_type" == "1" ] && echo "${core_sub}.2" || echo "${core_sub}.1")
               
               echo -ne "\n  ${C}●${NC} ${W}Run initial ping test to peer now? (y/n): ${NC}"; read -r run_initial_ping
               run_initial_ping=$(echo "$run_initial_ping" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$run_initial_ping" == "y" || "$run_initial_ping" == "yes" ]]; then
                   echo -e "  ${DIM}┌─[ INITIAL PING TEST TO PEER ]${NC}"
                   echo -e "  ${DIM}│${NC} Pinging ${remote_tip} (4 Packets)..."
                   ping_res=$(ping -c 4 -W 1 "$remote_tip" 2>&1)
                   if echo "$ping_res" | grep -q "time="; then
                       lat=$(echo "$ping_res" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d/ -f2)
                       lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
                       echo -e "  ${DIM}└─${NC} ${G}SUCCESS!${NC} Average Latency: ${Y}${lat_int}ms${NC}"
                   else
                       echo -e "  ${DIM}└─${NC} ${R}FAILED!${NC} Destination Host Unreachable."
                   fi
               fi
               
               echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Virtual IPs now? (y/n): ${NC}"; read -r setup_vip
               setup_vip=$(echo "$setup_vip" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$setup_vip" == "y" || "$setup_vip" == "yes" ]]; then
                   while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read -r n; [[ "$n" == "q" ]] && break; if is_uint "$n" && [ "$n" -le 64 ]; then break; fi; echo -e "  ${R}✖ Enter a number between 0 and 64.${NC}"; done
                   if [[ "$n" != "q" ]]; then
                       k=$tun_secret
                       echo -e "  ${DIM}● Sync Key automatically linked to Master Token.${NC}"
                       sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$conf_path"
                       sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$conf_path"
                       apply_tunnel "$conf_path"
                       echo -e "  ${G}● Virtual IPs applied successfully.${NC}"
                   fi
               fi

               if [ "$s_type" == "1" ]; then
                   echo -ne "\n  ${C}●${NC} ${W}Do you want to setup Port Forwarding? (y/n): ${NC}"; read -r setup_pf
                   setup_pf=$(echo "$setup_pf" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                   if [[ "$setup_pf" == "y" || "$setup_pf" == "yes" ]]; then
                       echo -ne "  ${C}●${NC} ${Y}NAT Forward TCP Ports (e.g. 80,443)  [Enter to skip]: ${NC}"; read -r fwd_tcp
                       echo -ne "  ${C}●${NC} ${C}NAT Forward UDP Ports (e.g. 53,7000) [Enter to skip]: ${NC}"; read -r fwd_udp
                       fwd_tcp=$(sanitize_ports "$fwd_tcp" tcp)
                       fwd_udp=$(sanitize_ports "$fwd_udp" udp)
                       
                       run_lb="0"
                       if [ -n "$fwd_tcp" ] || [ -n "$fwd_udp" ]; then
                           echo -ne "  ${C}●${NC} ${W}Load Balance across all Virtual IPs? (y/n): ${NC}"; read -r ask_lb
                           ask_lb=$(echo "$ask_lb" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                           if [[ "$ask_lb" == "y" || "$ask_lb" == "yes" ]]; then run_lb="1"; fi
                       fi
                       
                       grep -v "^FWD_TCP=" "$conf_path" | grep -v "^FWD_UDP=" | grep -v "^LB_MODE=" > "${conf_path}.tmp"
                       echo "FWD_TCP=$fwd_tcp" >> "${conf_path}.tmp"
                       echo "FWD_UDP=$fwd_udp" >> "${conf_path}.tmp"
                       echo "LB_MODE=$run_lb" >> "${conf_path}.tmp"
                       mv "${conf_path}.tmp" "$conf_path"
                       
                       apply_tunnel "$conf_path"
                       echo -e "  ${G}● Port Forwarding applied successfully.${NC}"
                   fi
               fi
               sleep 2
           else
               echo -e "\n  ${R}● FATAL ERROR: Kernel rejected tunnel creation!${NC}"; rm -f "$conf_path"; sleep 3.5
           fi ;;

        6)
           draw_mgre_header
           configs=("$CONF_DIR"/*.conf)
           [ ! -e "${configs[0]}" ] && echo -e "\n  ${R}● No active tunnels to remove!${NC}" && sleep 1.5 && continue
           echo -e "\n  ${B}╭────────────────── Select Tunnel to Erase ──────────────────╮${NC}"
           for i in "${!configs[@]}"; do printf "  ${B}│${NC}  ${Y}%-3.3s${NC} ${C}❯${NC} ${W}%-50.50s${NC}  ${B}│${NC}\n" "$((i+1))" "$(basename "${configs[$i]}" .conf)"; done
           echo -e "  ${B}╰────────────────────────────────────────────────────────────╯${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter Number [1-${#configs[@]}], 'all', or 'q': ${NC}"; read -r del_idx; del_idx=$(echo "$del_idx" | tr -d '\r ')
           [[ "$del_idx" == "q" || -z "$del_idx" ]] && continue
           if [[ "$del_idx" == "all" ]]; then
               echo -ne "  ${R}● DANGER: Delete ALL tunnels? (y/n): ${NC}"; read -r confirm_all
               if [[ "$confirm_all" == "y" ]]; then
                   for conf in "${configs[@]}"; do
                       teardown_tunnel "$conf"; rm -f "$conf"
                   done
                   rebuild_guard
                   echo -e "  ${G}● All tunnels safely purged.${NC}"; sleep 1.5
               fi; continue
           fi
           if d_zero=$(pick_index "$del_idx" "${#configs[@]}"); then
               T_NAME=""; source "${configs[$d_zero]}" 2>/dev/null
               echo -ne "  ${R}● Delete tunnel [${T_NAME}]? (y/n): ${NC}"; read -r confirm_one
               [[ "${confirm_one,,}" == "y" ]] || continue
               teardown_tunnel "${configs[$d_zero]}"; rm -f "${configs[$d_zero]}"; rebuild_guard
               echo -e "  ${G}● Tunnel [${T_NAME}] destroyed.${NC}"; sleep 1.5
           else
               echo -e "  ${R}✖ Invalid selection. Nothing deleted.${NC}"; sleep 1.5
           fi ;;

        2)
           select_tunnel_interactive || continue
           draw_mgre_header
           T_NAME=""; MAX_IPS="0"; TUN_SECRET=""; source "$SELECTED_CONF" 2>/dev/null
           echo -e "\n  ${DIM}┌─[ vIP ACTIONS for ${T_NAME} ]${NC}\n  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${G}Setup / Update Virtual IPs${NC}\n  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${R}Purge All Virtual IPs${NC}\n  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel${NC}"
           while true; do echo -ne "  ${C}Select Action ❯❯ ${NC}"; read -r vip_action; [[ "$vip_action" =~ ^[12q]$ ]] && break; done
           [[ "$vip_action" == "q" ]] && continue
           if [[ "$vip_action" == "1" ]]; then
               while true; do echo -ne "  ${C}●${NC} ${W}Virtual IPs Count: ${NC}"; read -r n; [[ "$n" == "q" ]] && break; if is_uint "$n" && [ "$n" -le 64 ]; then break; fi; echo -e "  ${R}✖ Enter a number between 0 and 64.${NC}"; done
               [[ "$n" == "q" ]] && continue
               
               k=$TUN_SECRET
               echo -e "  ${DIM}● Sync Key automatically linked to Master Token.${NC}"
               sed -i "s/^MAX_IPS=.*/MAX_IPS=$n/" "$SELECTED_CONF"
               sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$k/" "$SELECTED_CONF"
               apply_tunnel "$SELECTED_CONF"
               echo -e "  ${G}● IPs synchronized successfully.${NC}"; sleep 1.5
           elif [[ "$vip_action" == "2" ]]; then
               if [[ "$MAX_IPS" == "0" || -z "$MAX_IPS" ]]; then echo -e "  ${Y}● No Virtual IPs found!${NC}"; sleep 1.5; continue; fi
               echo -ne "  ${R}● Delete all ${MAX_IPS} vIPs from [${T_NAME}]? (y/n): ${NC}"; read -r confirm_vip
               if [[ "$confirm_vip" == "y" ]]; then 
                   sed -i "s/^MAX_IPS=.*/MAX_IPS=0/" "$SELECTED_CONF"
                   sed -i "s/^SYNC_KEY=.*/SYNC_KEY=/" "$SELECTED_CONF"
                   apply_tunnel "$SELECTED_CONF"
                   echo -e "  ${G}● Virtual IPs purged.${NC}"; sleep 1.5
               fi
           fi ;;

        3)
           if command -v mporter >/dev/null 2>&1; then
               mporter
           elif [ -x "/usr/bin/mporter" ]; then
               /usr/bin/mporter
           elif [ -f "/root/mtunnel/mporter.sh" ]; then
               bash /root/mtunnel/mporter.sh
           else
               echo -e "\n  ${R}✖ MPorter script not found on system!${NC}"; sleep 1.5
           fi ;;

        8)
           select_tunnel_interactive || continue
           draw_mgre_header
           LOCAL_PUB=""; REMOTE_PUB=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Local Public IP [${Y}${LOCAL_PUB}${W}]: ${NC}"; read -r new_local
           echo -ne "  ${C}●${NC} ${W}New Remote Public IP [${Y}${REMOTE_PUB}${W}]: ${NC}"; read -r new_remote
           new_local=$(echo "$new_local" | tr -dc '0-9.')
           new_remote=$(echo "$new_remote" | tr -dc '0-9.')
           if { [ -n "$new_local" ] && ! is_ipv4 "$new_local"; } || { [ -n "$new_remote" ] && ! is_ipv4 "$new_remote"; }; then
               echo -e "  ${R}✖ Invalid IPv4 address. Nothing changed.${NC}"; sleep 2; continue
           fi
           xfrm_clear "$T_NAME"
           [ -n "$new_local" ] && sed -i "s/^LOCAL_PUB=.*/LOCAL_PUB=$new_local/" "$SELECTED_CONF"
           [ -n "$new_remote" ] && sed -i "s/^REMOTE_PUB=.*/REMOTE_PUB=$new_remote/" "$SELECTED_CONF"
           apply_tunnel "$SELECTED_CONF"
           echo -e "  ${G}● Public IPs updated and applied.${NC}"; sleep 1.5 ;;

        9)
           select_tunnel_interactive || continue
           draw_mgre_header
           TUN_SECRET=""; T_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           xfrm_clear "$T_NAME"
           echo -ne "  ${C}●${NC} ${W}New Master Secret Token (Regenerates Network): ${NC}"; read -r new_tok
           new_tok=$(echo "$new_tok" | tr -dc 'a-zA-Z0-9_=-')
           if [ -n "$new_tok" ]; then
               hash_c=$(echo -n "core_${new_tok}" | sha256sum)
               new_tun_id=$(( 16#${hash_c:0:6} ))
               class_selector=$(( 16#${hash_c:6:2} % 3 ))
               c1=""; c2=""; c3=""
               if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
               elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 ))
               else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
               new_core_sub="${c1}.${c2}.${c3}"
               
               if grep -q "^TUN_ID=$new_tun_id$" "$CONF_DIR"/*.conf 2>/dev/null || subnet_in_use "$new_core_sub" "$SELECTED_CONF"; then
                   echo -e "  ${R}● Collision detected with an existing tunnel! Please use a different Token.${NC}"; sleep 2; continue
               fi
               
               sed -i "s/^TUN_SECRET=.*/TUN_SECRET=$new_tok/" "$SELECTED_CONF"
               sed -i "s/^TUN_ID=.*/TUN_ID=$new_tun_id/" "$SELECTED_CONF"
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_core_sub/" "$SELECTED_CONF"
               sed -i "s/^SYNC_KEY=.*/SYNC_KEY=$new_tok/" "$SELECTED_CONF"
               apply_tunnel "$SELECTED_CONF"
               echo -e "  ${G}● Token updated. Key: ${new_tun_id}, Subnet: ${new_core_sub}.x${NC}"; sleep 1.8
           fi ;;

        10)
           select_tunnel_interactive || continue
           draw_mgre_header
           CORE_SUBNET=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Core Subnet Base (e.g. 10.76.5) [Current: ${Y}${CORE_SUBNET}${W}]: ${NC}"; read -r new_sub
           new_sub=$(echo "$new_sub" | tr -dc '0-9.')
           if [ -n "$new_sub" ] && ! is_subnet3 "$new_sub"; then echo -e "  ${R}✖ Format must be X.Y.Z (e.g. 10.76.5).${NC}"; sleep 2; continue; fi
           if [ -n "$new_sub" ] && subnet_in_use "$new_sub" "$SELECTED_CONF"; then echo -e "  ${R}✖ ${new_sub}.x is already in use.${NC}"; sleep 2; continue; fi
           if [ -n "$new_sub" ]; then
               sed -i "s/^CORE_SUBNET=.*/CORE_SUBNET=$new_sub/" "$SELECTED_CONF"
               apply_tunnel "$SELECTED_CONF"
               echo -e "  ${G}● Subnet base updated to ${new_sub}.x${NC}"; sleep 1.5
           fi ;;

        4)
           select_tunnel_interactive || continue
           manage_port_forwarding "$SELECTED_CONF" ;;

        7)
           select_tunnel_interactive || continue
           draw_mgre_header
           T_NAME=""; TUN_PROTO=""; TYPE=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Interface Suffix (Current: ${Y}$(get_pure_tun_name "$T_NAME")${W}): ${NC}"; read -r new_suffix
           new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
           if [ -n "$new_suffix" ]; then
               pfx=$([ "$TUN_PROTO" == "6to4" ] && echo "$([ "$TYPE" == "1" ] && echo "gre6ir" || echo "gre6kh")" || echo "$([ "$TYPE" == "1" ] && echo "greir" || echo "grekh")")
               new_t_name="${pfx}${new_suffix}"
               check_len=${#new_t_name}; [ "$TUN_PROTO" == "6to4" ] && check_len=$((check_len + 4))
               if [ "$check_len" -gt 15 ]; then echo -e "  ${R}● Error: Name too long!${NC}"; sleep 1.5; continue; fi
               if [ -f "$CONF_DIR/${new_t_name}.conf" ]; then echo -e "  ${R}● Error: Interface exists!${NC}"; sleep 1.5; continue; fi
               
               teardown_tunnel "$SELECTED_CONF"
               
               sed -i "s/^T_NAME=.*/T_NAME=$new_t_name/" "$SELECTED_CONF"
               mv "$SELECTED_CONF" "$CONF_DIR/${new_t_name}.conf"
               SELECTED_CONF="$CONF_DIR/${new_t_name}.conf"
               apply_tunnel "$SELECTED_CONF"
               echo -e "  ${G}● Tunnel renamed to: ${new_t_name}${NC}"; sleep 1.5
           fi ;;

        11)
           select_tunnel_interactive || continue
           draw_mgre_header
           CUSTOM_MTU=""; TYPE=""; TUN_PROTO=""; T_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           read -r min_mtu max_mtu def_mtu <<< "$(mgre_mtu_limits "$TUN_PROTO")"

           act_mtu=""
           [ -d "/sys/class/net/$T_NAME" ] && act_mtu=$(cat "/sys/class/net/$T_NAME/mtu" 2>/dev/null)
           cur_mtu="${act_mtu:-${CUSTOM_MTU:-$def_mtu (Auto)}}"

           echo -e "\n  ${DIM}┌─[ MTU & TCP MSS CONFIGURATION: ${W}${T_NAME}${DIM} ]${NC}"
           echo -e "  ${DIM}│${NC} Current Live MTU : ${Y}${cur_mtu}${NC}"
           echo -e "  ${DIM}│${NC} Valid Range      : ${W}${min_mtu} - ${max_mtu}${NC}"
           echo -e "  ${DIM}│${NC} Profiles         : ${W}1436${NC} (Default IR) | ${W}1360${NC} (Iran Broadband) | ${W}900-1200${NC} (Heavy Fragmentation)"
           echo -e "  ${DIM}└─${NC}"
           echo -ne "  ${C}●${NC} ${W}Enter New MTU (${min_mtu}-${max_mtu}) [Enter for Auto]: ${NC}"; read -r new_mtu
           new_mtu=$(echo "$new_mtu" | tr -dc '0-9')

           if [ -z "$new_mtu" ]; then
               grep -v "^CUSTOM_MTU=" "$SELECTED_CONF" > "${SELECTED_CONF}.tmp"
               echo "CUSTOM_MTU=" >> "${SELECTED_CONF}.tmp"
               mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
               apply_tunnel "$SELECTED_CONF"
               echo -e "  ${G}● MTU reset to Auto ($def_mtu). MSS Clamping set to $((def_mtu - 40)).${NC}"; sleep 1.8
           elif [ "$new_mtu" -ge "$min_mtu" ] && [ "$new_mtu" -le "$max_mtu" ] 2>/dev/null; then
               grep -v "^CUSTOM_MTU=" "$SELECTED_CONF" > "${SELECTED_CONF}.tmp"
               echo "CUSTOM_MTU=$new_mtu" >> "${SELECTED_CONF}.tmp"
               mv "${SELECTED_CONF}.tmp" "$SELECTED_CONF"
               
               # 1. Update live interface immediately
               ip link set dev "$T_NAME" mtu "$new_mtu" 2>/dev/null
               
               # 2. Update MSS clamping rule
               # (MSS rule is rebuilt by apply_tunnel below)
               
               # 3. Synchronize full profile
               apply_tunnel "$SELECTED_CONF"

               # Check confirmed kernel value
               confirm_mtu=$(cat "/sys/class/net/$T_NAME/mtu" 2>/dev/null)
               echo -e "  ${G}✔ MTU successfully locked to ${new_mtu} (Kernel Confirmed: ${confirm_mtu:-$new_mtu} | MSS: $((new_mtu - 40))).${NC}"; sleep 2
           else
               echo -e "  ${R}✖ Invalid MTU! Value must be between ${min_mtu} and ${max_mtu}.${NC}"; sleep 2.5
           fi ;;

        12)
           while true; do
               draw_mgre_header
               show_mgre_monitor
               read -t 2 -n 1 -s b_opt
               [[ "$b_opt" == "q" || "$b_opt" == "Q" ]] && break
           done ;;

        5) show_tunnel_details ;;
        19) self_update_module ;;
        20) uninstall_mgre ;;
        15) menu_encrypt ;;
        16) menu_guard ;;
        17) menu_watchdog ;;
        14) menu_auto_mtu ;;
        13) show_traffic_monitor ;;
        18) menu_backup_restore ;;
        0) break ;;
    esac
done
