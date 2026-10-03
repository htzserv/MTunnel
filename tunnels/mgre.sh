#!/bin/bash
# --- MGRE Modular Core (mgre.sh) | MDesign Core v6.0.0 ---
# [Features: Symmetric Telemetry Header | Compact Peer Link | Dynamic MTU | Instant MSS Engine]
# [v6.5.0: Header rows = name ➔ local IPv4 ➔ remote IPv4 [TYPE] (same-name IPv4/IPv6 tunnels are now distinguishable) | IPv6 2nd header line removed
#          | optional "Remote Server IPv4" (REMOTE_V4) in setup + Edit IPs | Live in-place header refresh (ping/loss/uptime, no full-screen redraw)
#          | Update badge repaints the menu live without erasing typed text | Background signals can no longer interrupt/erase prompt input]
# [v6.4.0: GRE6 / IPIP4>4 / IPIP4>6 / IPIP6>6 | IPv6-aware header (2nd line) | locale-safe layout | shared proto helpers]
# [v6.0.0: Quote-safe iptables cleanup | Safe index pickers | Cross-tool subnet guard | SSH-safe DNAT
#          | Correct MTU math | IPsec ESP | Firewall Guard | Watchdog + LB health | Auto-MTU | Traffic | Backup | CLI]

MODULE_VERSION="6.5.2"

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

# Strict-enough IPv6 literal check (no zone ids, no embedded IPv4)
is_ipv6() {
    local ip="$1" g n=0 f=0 dbl=0 rest
    local -a parts
    [ -n "$ip" ] && [ "${#ip}" -le 39 ] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" == *:::* ]] && return 1
    if [[ "$ip" == *::* ]]; then
        rest="${ip#*::}"; [[ "$rest" == *::* ]] && return 1
        dbl=1
    fi
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1
    IFS=':' read -ra parts <<< "$ip"
    for g in "${parts[@]}"; do
        f=$((f+1))
        [ -z "$g" ] && continue
        [ "${#g}" -le 4 ] || return 1
        n=$((n+1))
    done
    if [ "$dbl" -eq 1 ]; then
        [ "$n" -le 7 ] || return 1
    else
        { [ "$n" -eq 8 ] && [ "$f" -eq 8 ]; } || return 1
    fi
    return 0
}
# IPv6 usable as a tunnel endpoint (rejects ::, ::1, link-local fe80::/10, multicast)
is_global_ipv6() {
    local ip="${1,,}"
    is_ipv6 "$ip" || return 1
    case "$ip" in ::|::1|fe8*|fe9*|fea*|feb*|ff*) return 1 ;; esac
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
    local tbl="$1" ch="$2" tag="$3" r bin="${IPT_BIN:-iptables}"
    "$bin" -t "$tbl" -S "$ch" 2>/dev/null | grep -E -- "--comment \"?${tag}\"?( |$)" | sed 's/^-A /-D /' | \
    while IFS= read -r r; do
        [ -n "$r" ] && echo "$r" | xargs "$bin" -t "$tbl" 2>/dev/null
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
    local plen=32
    if [[ "$lip" == *:* ]]; then
        plen=128
        [ -n "$(ip -6 -o addr show to "$lip" 2>/dev/null)" ] || { echo "  [xfrm] $name: local IP $lip not on this host, encryption skipped" >&2; return 1; }
    else
        ip -4 addr show 2>/dev/null | grep -qF "inet $lip/" || { echo "  [xfrm] $name: local IP $lip not on this host (NAT?), encryption skipped" >&2; return 1; }
    fi
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
    ip xfrm policy add src "$lip/$plen" dst "$rip/$plen" $sel dir out tmpl src "$lip" dst "$rip" proto esp reqid "$reqid" mode transport 2>/dev/null
    ip xfrm policy add src "$rip/$plen" dst "$lip/$plen" $sel dir in  tmpl src "$rip" dst "$lip" proto esp reqid "$reqid" mode transport 2>/dev/null
    {
        echo "ip xfrm policy delete src $lip/$plen dst $rip/$plen $sel dir out"
        echo "ip xfrm policy delete src $rip/$plen dst $lip/$plen $sel dir in"
        echo "ip xfrm state delete src $lip dst $rip proto esp spi $spi_out"
        echo "ip xfrm state delete src $rip dst $lip proto esp spi $spi_in"
    } > "$(xfrm_state_file "$name")"
    chmod 600 "$(xfrm_state_file "$name")" 2>/dev/null
    return 0
}

# ---- Path MTU probe towards the remote public IP (needs ICMP echo on peer) ----
probe_path_mtu() {
    local dst="$1" lo=500 hi=1472 mid best=0 hdr=28 pc="ping"
    if [[ "$dst" == *:* ]]; then pc="ping -6"; hi=1452; hdr=48; fi   # IPv6: 40 (IP) + 8 (ICMPv6)
    $pc -c1 -W1 -M do -s "$lo" "$dst" >/dev/null 2>&1 || { echo 0; return; }
    best=$lo
    while [ "$lo" -le "$hi" ]; do
        mid=$(( (lo + hi) / 2 ))
        if $pc -c1 -W1 -M do -s "$mid" "$dst" >/dev/null 2>&1; then best=$mid; lo=$((mid + 1)); else hi=$((mid - 1)); fi
    done
    echo $((best + hdr))
}

auto_mtu_for_gre() {
    local dst="$1" proto="$2" pmtu overhead min_mtu max_mtu fallback mtu
    read -r min_mtu max_mtu fallback <<< "$(mgre_mtu_limits "$proto")"
    pmtu=$(probe_path_mtu "$dst")
    overhead=$(mgre_overhead "$proto")
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


# ---- Protocol / endpoint helpers: ipv4 (GRE) | 6to4 | gre6 | ipip4to4 | ipip4to6 | ipip6to6 ----
mgre_proto_label() {
    case "$1" in
        6to4) echo "6to4 IP6GRE" ;;   gre6) echo "Direct GRE6" ;;
        ipip4to4) echo "IPIP4→4" ;;   ipip4to6) echo "IPIP4→6" ;;
        ipip6to6) echo "IPIP6→6" ;;   *) echo "IPv4 GRE" ;;
    esac
}
mgre_proto_tag() {
    case "$1" in
        6to4) echo "6to4" ;;          gre6) echo "GRE6" ;;
        ipip4to4) echo "IPIP4>4" ;;   ipip4to6) echo "IPIP4>6" ;;
        ipip6to6) echo "IPIP6>6" ;;   *) echo "GRE" ;;
    esac
}
mgre_proto_is_v6() { case "$1" in gre6|ipip4to6|ipip6to6) return 0 ;; esac; return 1; }

# Interface name prefix: <proto> <type 1=IR|2=KH>
mgre_name_prefix() {
    local ir=0; [ "$2" == "1" ] && ir=1
    case "$1" in
        6to4|gre6) [ "$ir" -eq 1 ] && echo g6ir || echo g6kh ;;
        ipip4to4)  [ "$ir" -eq 1 ] && echo i4ir || echo i4kh ;;
        ipip4to6)  [ "$ir" -eq 1 ] && echo i46i || echo i46k ;;
        ipip6to6)  [ "$ir" -eq 1 ] && echo i66i || echo i66k ;;
        *)         [ "$ir" -eq 1 ] && echo greir || echo grekh ;;
    esac
}

# Outer (underlay) endpoints of the currently sourced conf -> EP_L EP_R EP_V6
mgre_endpoints() {
    if mgre_proto_is_v6 "$TUN_PROTO"; then
        EP_V6=1; EP_L="${LOCAL_PUB6:-$LOCAL_IP6}"; EP_R="${REMOTE_PUB6:-$REMOTE_IP6}"
    else
        EP_V6=0; EP_L="$LOCAL_PUB"; EP_R="$REMOTE_PUB"
    fi
}

# Inner core addresses + the right ping command (role-aware) -> CORE_LIP CORE_TIP CORE_PING
mgre_core_ips() {
    if [ "$TUN_PROTO" == "ipip6to6" ]; then
        CORE_PING="ping -6"
        if [ "$TYPE" == "1" ]; then CORE_LIP="${CORE_V6}::1"; CORE_TIP="${CORE_V6}::2"; else CORE_LIP="${CORE_V6}::2"; CORE_TIP="${CORE_V6}::1"; fi
    else
        CORE_PING="ping"
        if [ "$TYPE" == "1" ]; then CORE_LIP="${CORE_SUBNET}.1"; CORE_TIP="${CORE_SUBNET}.2"; else CORE_LIP="${CORE_SUBNET}.2"; CORE_TIP="${CORE_SUBNET}.1"; fi
    fi
}

# Encapsulation overhead in bytes (outer IP + tunnel header)
mgre_overhead() {
    case "$1" in
        6to4) echo 68 ;; gre6) echo 48 ;; ipip4to4) echo 20 ;; ipip4to6|ipip6to6) echo 40 ;; *) echo 28 ;;
    esac
}

# IPsec selector for a protocol (empty = encryption not supported for it)
mgre_enc_selector() {
    case "$1" in
        ipv4|gre6|"") echo "proto gre" ;; 6to4) echo "proto 41" ;; ipip4to4) echo "proto 4" ;; *) echo "" ;;
    esac
}

# Deterministic inner IPv6 /64 prefix for IPIP6>6 (same derivation on both peers)
mgre_gen_core_v6() {
    local h; h=$(echo -n "ipip6_${1}" | sha256sum)
    echo "fd${h:0:2}:${h:2:4}:${h:6:4}:${h:10:4}"
}

# Stable global IPv6 of this host (skips privacy/temporary addresses)
get_local_ipv6() {
    local ip
    ip=$(ip -6 -o addr show scope global 2>/dev/null | grep -v -E 'temporary|deprecated|tentative' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    [ -z "$ip" ] && ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1 | tr -d ' \n')
    echo "${ip,,}"
}

if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null
    chmod +x "$INSTALL_PATH" 2>/dev/null
fi

MAIN_PID=$$
NEED_REFRESH=false
trap '' SIGUSR1   # ignored: a signal must never interrupt typing in any prompt

UPDATE_CHECK_INTERVAL=60
PING_CHECK_INTERVAL=5

# Live header: repaint ONLY the header box in place (cursor saved/restored, nothing else touched).
# LIVE_HEADER_FUNC = header function, LIVE_ROWS = number of lines printed above the prompt line.
LIVE_HEADER_FUNC=""
LIVE_ROWS=0
LIVE_HEADER_INTERVAL=2
LIVE_MENU_FUNC=""        # menu renderer: redrawn (typed text kept) when the watcher finds a new remote version
LIVE_FRAME_FILE=""
LIVE_VER_FILE="$SECURE_TMP/.mgre_remote_ver"

live_header_tick() {
    [ -n "$LIVE_HEADER_FUNC" ] || return 0
    local rows frame
    rows=$(stty size 2>/dev/null | awk '{print $1}'); [ -z "$rows" ] && rows="${LINES:-24}"
    # page taller than the terminal -> header already scrolled off-screen, never paint over the menu
    [ "$LIVE_ROWS" -ge "$rows" ] && return 0
    frame=$(HEADER_LIVE=1 "$LIVE_HEADER_FUNC")
    printf '\e7\e[%dA\r%s\e8' "$LIVE_ROWS" "$frame"
}

read_with_refresh() {
    local prompt="$1"
    local __resultvar="$2"
    local buffer=""
    local char rc now last_refresh upd_seen="" upd_cur=""
    printf -v last_refresh '%(%s)T' -1
    [ -f "$LIVE_VER_FILE" ] && read -r upd_seen < "$LIVE_VER_FILE"

    echo -ne "$prompt"

    while true; do
        printf -v now '%(%s)T' -1
        if [ $((now - last_refresh)) -ge "$LIVE_HEADER_INTERVAL" ]; then
            last_refresh=$now
            live_header_tick
        fi

        # new version found by the background watcher -> repaint the menu so the update badge shows live
        upd_cur=""; [ -f "$LIVE_VER_FILE" ] && read -r upd_cur < "$LIVE_VER_FILE"
        if [ "$upd_cur" != "$upd_seen" ]; then
            upd_seen="$upd_cur"
            if [ -n "$LIVE_MENU_FUNC" ] && [ -n "$LIVE_FRAME_FILE" ]; then
                "$LIVE_MENU_FUNC" > "$LIVE_FRAME_FILE"; cat "$LIVE_FRAME_FILE"
                LIVE_ROWS=$(( $(wc -l < "$LIVE_FRAME_FILE") ))
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
    [ -n "$gh_ver" ] && printf '%s\n' "$gh_ver" > "$SECURE_TMP/.mgre_remote_ver_github"
    [ -n "$mirror_ver" ] && printf '%s\n' "$mirror_ver" > "$SECURE_TMP/.mgre_remote_ver_mirror"
    local latest_ver=""
    latest_ver=$(printf '%s\n' "$gh_ver" "$mirror_ver" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' | sort -V | tail -n 1)
    if [ -n "$latest_ver" ]; then
        printf '%s\n' "$latest_ver" > "$SECURE_TMP/.mgre_remote_ver"
    fi
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
    local conf TYPE T_NAME CORE_SUBNET CORE_V6 TUN_PROTO tip res loss avg
    > "$SECURE_TMP/.mgre_stats_cache.tmp"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; CORE_SUBNET=""; CORE_V6=""; TUN_PROTO="ipv4"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        
        ((count++))
        [ "$count" -gt 3 ] && break

        mgre_core_ips; tip="$CORE_TIP"
        res=$(timeout 2 $CORE_PING -c 3 -i 0.2 -W 1 "$tip" 2>/dev/null)
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

# Primary global IPv6 of this host (empty if none)


# Interface name prefix: <proto> <type 1=IR|2=KH>


get_pure_tun_name() {
    local pure="$1" p
    for p in gre6ir gre6kh g6ir g6kh greir grekh i46i i46k i66i i66k i4ir i4kh; do
        if [[ "$pure" == "$p"* ]]; then pure="${pure#"$p"}"; break; fi
    done
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

    [ -z "$HEADER_LIVE" ] && clear
    echo ""
    local border
    local BOXW=125 extra tw
    extra=$(( BOXW - 117 )); tw=$(( 24 + extra ))
    printf -v border '%*s' "$BOXW" ''
    border="${border// /─}"

    echo -e "  ${B}╭${border}╮${NC}"
    printf "  ${B}│${NC} ${W}%-34.34s${NC} ${B}│${NC} ${DIM}Local:${NC} ${W}%-25.25s${NC} ${B}│${NC} ${DIM}Active Tunnels:${NC} ${G}%-3.3s${NC}%-${tw}.${tw}s ${B}│${NC}\n" \
        "MGRE Core v${MODULE_VERSION}" "$s_ip" "$active_tunnels" ""
    echo -e "  ${B}├${border}┤${NC}"

    local shown=0
    local TYPE REMOTE_PUB T_NAME CORE_SUBNET FWD_TCP FWD_UDP MAX_IPS TUN_SECRET TUN_PROTO LOCAL_PUB6 REMOTE_PUB6 LOCAL_IP6 REMOTE_IP6 REMOTE_V4
    local local_txt pure_name vip_stat vip_col peer_txt tag_txt is_v6 proto_tag
    local live_ping live_loss cached_entry loss_disp loss_col fwd_str tun_uptime stat_icon stat_col fwd_col sec_disp
    local len_name len_rem pad_peer sp_peer
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; T_NAME=""; CORE_SUBNET=""; FWD_TCP=""; FWD_UDP=""; MAX_IPS="0"; TUN_SECRET=""
        TUN_PROTO="ipv4"; LOCAL_PUB6=""; REMOTE_PUB6=""; LOCAL_IP6=""; REMOTE_IP6=""; REMOTE_V4=""
        source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        ((shown++))
        [ "$shown" -gt 3 ] && break

        pure_name=$(get_pure_tun_name "$T_NAME")
        pure_name="${pure_name:0:10}"

                is_v6=0; mgre_proto_is_v6 "$TUN_PROTO" && is_v6=1
        proto_tag=$(mgre_proto_tag "$TUN_PROTO")
        if [ "$is_v6" -eq 1 ]; then
            # IPv6-outer tunnel: show the peer's IPv4 (same look as IPv4 tunnels); tag only if no IPv4 was stored
            if is_ipv4 "$REMOTE_V4"; then peer_txt="${REMOTE_V4:0:18}"; else peer_txt="---"; fi
        else peer_txt="${REMOTE_PUB:0:18}"; fi

        len_name=${#pure_name}
        tag_txt="[${proto_tag}]"
        # Local IPv4: the tunnel's own IPv4 endpoint, or this host's primary IPv4 for IPv6-underlay tunnels
        local_txt="${LOCAL_PUB:0:15}"
        [ -z "$local_txt" ] && local_txt="${s_ip:0:15}"
        [ -z "$local_txt" ] && local_txt="---"
        [ -z "$peer_txt" ] && peer_txt="---"
        # row = name ➔ local ➔ remote [TYPE]; the second arrow and spaces count as 5 columns
        len_rem=$(( ${#local_txt} + 3 + ${#peer_txt} + 1 + ${#tag_txt} ))
        pad_peer=$(( 38 + extra - (len_name + len_rem) ))
        if [ "$pad_peer" -lt 0 ]; then
            # too wide: shorten the name (never below 3 chars), then clamp
            len_name=$(( len_name + pad_peer )); [ "$len_name" -lt 3 ] && len_name=3
            pure_name="${pure_name:0:len_name}"
            pad_peer=$(( 38 + extra - (len_name + len_rem) )); [ "$pad_peer" -lt 0 ] && pad_peer=0
        fi
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

        printf "  ${B}│${NC} %b%s%b ${W}%s${NC} ${DIM}➔${NC} ${Y}%s${NC} ${DIM}➔${NC} ${Y}%s${NC} ${C}%s${NC}%s ${B}│${NC} ${DIM}vIP:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Ping:${NC}${Y}%-4.4s${NC} ${B}│${NC} ${DIM}Loss:${NC}%b%-4.4s%b ${B}│${NC} ${DIM}Up:${NC}${W}%-6.6s${NC} ${B}│${NC} ${DIM}FWD:${NC}%b%-5.5s%b ${B}│${NC} ${DIM}Sec:${NC}${M}%-5.5s${NC} ${B}│${NC}\n" \
            "$stat_col" "$stat_icon" "$NC" "$pure_name" "$local_txt" "$peer_txt" "$tag_txt" "$sp_peer" "$vip_col" "$vip_stat" "$NC" "$live_ping" "$loss_col" "$loss_disp" "$NC" "$tun_uptime" "$fwd_col" "$fwd_str" "$NC" "$sec_disp"

    done

    if [ "$shown" -eq 0 ]; then
        printf "  ${B}│${NC}  ${DIM}● %-$((111+extra)).$((111+extra))s${NC}  ${B}│${NC}\n" "No active tunnels configured on this host."
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
    local TYPE="" LOCAL_PUB="" REMOTE_PUB="" LOCAL_PUB6="" REMOTE_PUB6="" MAX_IPS="0" SYNC_KEY="" TUN_SECRET="" T_NAME="" TUN_ID="" CORE_SUBNET="" CORE_V6="" TUN_PROTO="ipv4" LOCAL_IP6="" REMOTE_IP6="" FWD_TCP="" FWD_UDP="" LB_MODE="0" CUSTOM_MTU="" ENCRYPT="0"
    source "$conf" 2>/dev/null
    [ -z "$T_NAME" ] && return
    mgre_endpoints; mgre_core_ips

    clean_mss_rules "$T_NAME"
    clean_fwd_rules "$T_NAME"
    xfrm_clear "$T_NAME"
    ip link del "$T_NAME" >/dev/null 2>&1; ip link del "sit_$T_NAME" >/dev/null 2>&1

    local min_mtu max_mtu def_mtu
    read -r min_mtu max_mtu def_mtu <<< "$(mgre_mtu_limits "$TUN_PROTO")"
    local eff_mtu="$CUSTOM_MTU"
    if ! is_uint "$eff_mtu"; then
        eff_mtu="$def_mtu"; [ "$ENCRYPT" == "1" ] && eff_mtu=$((def_mtu - 64))
    fi
    [ "$eff_mtu" -lt "$min_mtu" ] && eff_mtu="$min_mtu"
    [ "$eff_mtu" -gt "$max_mtu" ] && eff_mtu="$max_mtu"

    case "$TUN_PROTO" in
        6to4)
            ip tunnel add "sit_$T_NAME" mode sit remote "$REMOTE_PUB" local "$LOCAL_PUB" 2>/dev/null
            ip link set dev "sit_$T_NAME" mtu 1480 2>/dev/null; ip link set "sit_$T_NAME" up 2>/dev/null
            ip -6 addr add "$LOCAL_IP6/64" dev "sit_$T_NAME" 2>/dev/null
            ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" encaplimit none 2>/dev/null \
                || ip -6 tunnel add "$T_NAME" mode ip6gre remote "$REMOTE_IP6" local "$LOCAL_IP6" key "$TUN_ID" 2>/dev/null
            ;;
        gre6)
            ip -6 tunnel add "$T_NAME" mode ip6gre remote "$EP_R" local "$EP_L" key "$TUN_ID" encaplimit none 2>/dev/null \
                || ip -6 tunnel add "$T_NAME" mode ip6gre remote "$EP_R" local "$EP_L" key "$TUN_ID" 2>/dev/null \
                || ip link add "$T_NAME" type ip6gre remote "$EP_R" local "$EP_L" ikey "$TUN_ID" okey "$TUN_ID" encaplimit none 2>/dev/null
            ;;
        ipip4to4)
            ip tunnel add "$T_NAME" mode ipip remote "$EP_R" local "$EP_L" ttl 255 2>/dev/null
            ;;
        ipip4to6)
            ip -6 tunnel add "$T_NAME" mode ipip6 remote "$EP_R" local "$EP_L" encaplimit none 2>/dev/null \
                || ip -6 tunnel add "$T_NAME" mode ipip6 remote "$EP_R" local "$EP_L" 2>/dev/null
            ;;
        ipip6to6)
            ip -6 tunnel add "$T_NAME" mode ip6ip6 remote "$EP_R" local "$EP_L" encaplimit none 2>/dev/null \
                || ip -6 tunnel add "$T_NAME" mode ip6ip6 remote "$EP_R" local "$EP_L" 2>/dev/null
            ;;
        *)
            ip tunnel add "$T_NAME" mode gre remote "$REMOTE_PUB" local "$LOCAL_PUB" ttl 255 key "$TUN_ID" 2>/dev/null
            ;;
    esac

    ip link set dev "$T_NAME" mtu "$eff_mtu" 2>/dev/null
    ip link set "$T_NAME" up 2>/dev/null

    if [ "$TUN_PROTO" == "ipip6to6" ]; then
        ip -6 addr add "$CORE_LIP/64" dev "$T_NAME" nodad 2>/dev/null || ip -6 addr add "$CORE_LIP/64" dev "$T_NAME" 2>/dev/null
        ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -m comment --comment "MGRE_MSS_$T_NAME" -j TCPMSS --set-mss $((eff_mtu - 60)) 2>/dev/null
    else
        ip addr add "$CORE_LIP/30" dev "$T_NAME" 2>/dev/null
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$T_NAME" -m comment --comment "MGRE_MSS_$T_NAME" -j TCPMSS --set-mss $((eff_mtu - 40)) 2>/dev/null
    fi

    if [ "$ENCRYPT" == "1" ]; then
        local sel; sel=$(mgre_enc_selector "$TUN_PROTO")
        if [ -n "$sel" ]; then xfrm_apply "$T_NAME" "$TYPE" "$EP_L" "$EP_R" "$TUN_SECRET" $sel
        else echo "  [xfrm] $T_NAME: IPsec is not supported for $(mgre_proto_label "$TUN_PROTO"); tunnel stays unencrypted." >&2; fi
    fi

    if [ "$TUN_PROTO" != "ipip6to6" ] && is_uint "$MAX_IPS" && [ "$MAX_IPS" -gt 0 ]; then
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
    local conf TYPE LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET CORE_V6 TUN_PROTO LOCAL_IP6 REMOTE_IP6 FWD_TCP FWD_UDP LB_MODE
    local v_ips title_color proto_lbl title_txt pad1 sp1 eval_l1 disp_tcp disp_udp lb_txt raw_l2 pad2 sp2 lb_stat eval_l2 pad_p sp_p
    local main_tip main_lip ping_res lat lat_int lat_raw lat_color stat_icon stat_text stat_color m_icon total_v idx lip base_ip last tip v_icon

    for conf in "$CONF_DIR"/*.conf; do
        [ ! -f "$conf" ] && continue
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; CORE_V6=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        mgre_endpoints; mgre_core_ips
        mapfile -t v_ips < <(ip -4 addr show dev "$T_NAME" label "${T_NAME}:m" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

        proto_lbl=$(mgre_proto_tag "$TUN_PROTO")
        title_color="${C}"
        [[ "$TUN_PROTO" == "6to4" ]] && title_color="${M}"
        [ "$EP_V6" -eq 1 ] && title_color="${G}"
        title_txt="${T_NAME} [${proto_lbl}]"

        # Widths are computed from ASCII parts only (arrows/markers are 1 column but multi-byte): locale-safe
        if [ "$EP_V6" -eq 1 ]; then
            pad1=$(( 92 - 3 - ${#title_txt} ))
            eval_l1=$(printf " %b▼ %s%b" "${title_color}" "${title_txt}" "${NC}")
        else
            pad1=$(( 92 - 14 - ${#title_txt} - ${#EP_L} - ${#EP_R} ))
            eval_l1=$(printf " %b▼ %s%b ${DIM}| PUB: ${W}%s ${DIM}→${W} %s${NC}" "${title_color}" "${title_txt}" "${NC}" "${EP_L}" "${EP_R}")
        fi
        [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "  ${B}│${NC}${eval_l1}${sp1}${B}│${NC}"
        if [ "$EP_V6" -eq 1 ]; then
            pad_p=$(( 92 - 13 - ${#EP_L} - ${#EP_R} )); [ "$pad_p" -lt 0 ] && pad_p=0; sp_p=$(printf '%*s' "$pad_p" "")
            echo -e "  ${B}│${NC}   ${DIM}↳ PUB:${NC} ${W}${EP_L}${NC} ${DIM}→${NC} ${W}${EP_R}${NC}${sp_p}${B}│${NC}"
        fi

        if [ "$TYPE" == "1" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
            disp_tcp="${FWD_TCP:-0}"; [ ${#disp_tcp} -gt 30 ] && disp_tcp="${disp_tcp:0:27}..."
            disp_udp="${FWD_UDP:-0}"; [ ${#disp_udp} -gt 30 ] && disp_udp="${disp_udp:0:27}..."
            lb_txt="OFF"; [ "$LB_MODE" == "1" ] && lb_txt="ON"
            raw_l2="   > NAT: T:[${disp_tcp}] U:[${disp_udp}] LB:[${lb_txt}]"
            pad2=$(( 92 - ${#raw_l2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
            lb_stat=$([ "$LB_MODE" == "1" ] && echo -e "${G}ON${NC}" || echo -e "${DIM}OFF${NC}")
            eval_l2="   ${DIM}↳ NAT:${NC} ${Y}T:[${disp_tcp}]${NC} ${C}U:[${disp_udp}]${NC} ${DIM}LB:[${lb_stat}${DIM}]${NC}"
            echo -e "  ${B}│${NC}${eval_l2}${sp2}${B}│${NC}"
        fi

        echo -e "  ${B}├────────────────────┬────────────────────┬────────────────────┬──────────────┬──────────────┤${NC}"
        printf "  ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-18.18s${NC} ${B}│${NC} ${DIM}%-12.12s${NC} ${B}│${NC} ${DIM}%-12.12s${NC} ${B}│${NC}\n" "TYPE" "LOCAL IP" "TARGET IP" "LATENCY" "STATUS"
        echo -e "  ${B}├────────────────────┼────────────────────┼────────────────────┼──────────────┼──────────────┤${NC}"

        main_tip="$CORE_TIP"; main_lip="$CORE_LIP"
        ping_res=$(timeout 2 $CORE_PING -c 1 -W 1 "$main_tip" 2>/dev/null)
        if echo "$ping_res" | grep -q "time="; then
            lat=$(echo "$ping_res" | grep -oP 'time=\K[0-9.]+')
            lat_int=$(awk -v v="$lat" 'BEGIN {printf "%.0f", v}')
            lat_raw="${lat_int}ms"; lat_color="${Y}"; stat_icon="●"; stat_text="ONLINE"; stat_color="${G}"
        else lat_raw="---"; lat_color="${DIM}"; stat_icon="○"; stat_text="OFFLINE"; stat_color="${R}"; fi

        m_icon="├─"; [ ${#v_ips[@]} -eq 0 ] && m_icon="└─"
        [ ${#main_lip} -gt 18 ] && main_lip="${main_lip:0:17}~"
        [ ${#main_tip} -gt 18 ] && main_tip="${main_tip:0:17}~"
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
    local conf TYPE LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 MAX_IPS SYNC_KEY TUN_SECRET T_NAME TUN_ID CORE_SUBNET CORE_V6 TUN_PROTO LOCAL_IP6 REMOTE_IP6 FWD_TCP FWD_UDP LB_MODE CUSTOM_MTU ENCRYPT
    local lip tip t_role t_sec t_id proto_lbl lb_txt left_p right_p pad sp l1 r1 pad1 sp1 l2 r2 pad2 sp2 l3 r3 pad3 sp3 l4 pad4 sp4 l5 r5 pad5 sp5 act_mtu def_mtu curr_mtu sync_disp fwd_disp tn_s
    for conf in "${configs[@]}"; do
        TYPE=""; LOCAL_PUB=""; REMOTE_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; MAX_IPS="0"; SYNC_KEY=""; TUN_SECRET=""; T_NAME=""; TUN_ID=""; CORE_SUBNET=""; CORE_V6=""; TUN_PROTO="ipv4"; LOCAL_IP6=""; REMOTE_IP6=""; FWD_TCP=""; FWD_UDP=""; LB_MODE="0"; CUSTOM_MTU=""; ENCRYPT="0"; source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        mgre_endpoints; mgre_core_ips
        lip="$CORE_LIP"; tip="$CORE_TIP"
        t_role=$([ "$TYPE" == "1" ] && echo "IRAN (Access)" || echo "KHAREJ (Gateway)")
        t_sec="${TUN_SECRET:-[ NOT SET ]}"
        t_id="${TUN_ID:-[ NOT SET ]}"

        act_mtu=""
        [ -d "/sys/class/net/$T_NAME" ] && act_mtu=$(cat "/sys/class/net/$T_NAME/mtu" 2>/dev/null)
        def_mtu=$(mgre_mtu_limits "$TUN_PROTO" | awk '{print $3}')
        curr_mtu="${act_mtu:-${CUSTOM_MTU:-$def_mtu (Auto)}}"
        proto_lbl=$(mgre_proto_label "$TUN_PROTO")

        echo -e "  ${B}╭────────────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        # widths use ASCII-only measures (markers/arrows are 1 column but multi-byte): locale-safe
        tn_s="${T_NAME:0:25}"; left_p="▼ Tunnel: ${tn_s}"; right_p="Role: $t_role"
        pad=$(( 90 - (10 + ${#tn_s}) - ${#right_p} )); [ "$pad" -lt 0 ] && pad=0; sp=$(printf '%*s' "$pad" "")
        echo -e "  ${B}│${NC} ${C}${left_p}${NC}${sp}${DIM}${right_p}${NC} ${B}│${NC}"
        echo -e "  ${B}├────────────────────────────────────────────────────────────────────────────────────────────┤${NC}"

        l1="Master Token : ${t_sec:0:25}"; r1="Protocol: ${proto_lbl//→/>}"
        pad1=$(( 90 - ${#l1} - ${#r1} )); [ "$pad1" -lt 0 ] && pad1=0; sp1=$(printf '%*s' "$pad1" "")
        echo -e "  ${B}│${NC} ${M}Master Token :${NC} ${W}${t_sec:0:25}${NC}${sp1}${DIM}Protocol:${NC} ${W}${proto_lbl}${NC} ${B}│${NC}"

        sync_disp="${SYNC_KEY:-Same As Token}"; sync_disp="${sync_disp:0:25}"
        l2="vIP Sync Key : ${sync_disp}"; r2="Network Key ID: ${t_id:0:15}"
        pad2=$(( 90 - ${#l2} - ${#r2} )); [ "$pad2" -lt 0 ] && pad2=0; sp2=$(printf '%*s' "$pad2" "")
        echo -e "  ${B}│${NC} ${C}vIP Sync Key :${NC} ${W}${sync_disp}${NC}${sp2}${DIM}Network Key ID:${NC} ${Y}${t_id:0:15}${NC} ${B}│${NC}"

        if [ "$EP_V6" -eq 1 ]; then
            l3="Local Pub IP : ${EP_L}"; r3="MTU: ${curr_mtu}"
            pad3=$(( 90 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
            echo -e "  ${B}│${NC} ${DIM}Local Pub IP :${NC} ${W}${EP_L}${NC}${sp3}${DIM}MTU:${NC} ${G}${curr_mtu}${NC} ${B}│${NC}"
            l3="Remote Pub IP: ${EP_R}"
            pad3=$(( 90 - ${#l3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
            echo -e "  ${B}│${NC} ${DIM}Remote Pub IP:${NC} ${W}${EP_R}${NC}${sp3} ${B}│${NC}"
        else
            l3="Public IPs   : ${EP_L:0:16} -> ${EP_R:0:16}"; r3="MTU: ${curr_mtu}"
            pad3=$(( 90 - ${#l3} - ${#r3} )); [ "$pad3" -lt 0 ] && pad3=0; sp3=$(printf '%*s' "$pad3" "")
            echo -e "  ${B}│${NC} ${DIM}Public IPs   :${NC} ${W}${EP_L:0:16}${NC} ${DIM}->${NC} ${W}${EP_R:0:16}${NC}${sp3}${DIM}MTU:${NC} ${G}${curr_mtu}${NC} ${B}│${NC}"
        fi

        if [ "$TUN_PROTO" == "ipip6to6" ]; then
            l4="Core IPv6    : ${lip} -> ${tip}"
            pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
            echo -e "  ${B}│${NC} ${DIM}Core IPv6    :${NC} ${G}${lip}${NC} ${DIM}->${NC} ${G}${tip}${NC}${sp4} ${B}│${NC}"
        else
            l4="Core Subnet  : ${CORE_SUBNET}.x (${lip} -> ${tip})"
            pad4=$(( 90 - ${#l4} )); [ "$pad4" -lt 0 ] && pad4=0; sp4=$(printf '%*s' "$pad4" "")
            echo -e "  ${B}│${NC} ${DIM}Core Subnet  :${NC} ${G}${CORE_SUBNET}.x${NC} ${DIM}(${lip} -> ${tip})${NC}${sp4} ${B}│${NC}"
        fi

        if [ "$TYPE" == "1" ] && [ "$TUN_PROTO" != "ipip6to6" ]; then
            lb_txt=$([ "$LB_MODE" == "1" ] && echo "Active (All vIPs)" || echo "Direct (Core IP)")
            fwd_disp="${FWD_TCP:-None}"; [ ${#fwd_disp} -gt 25 ] && fwd_disp="${fwd_disp:0:22}..."
            l5="NAT FWD TCP  : ${fwd_disp}"; r5="Load Balancer: ${lb_txt}"
            pad5=$(( 90 - ${#l5} - ${#r5} )); [ "$pad5" -lt 0 ] && pad5=0; sp5=$(printf '%*s' "$pad5" "")
            echo -e "  ${B}│${NC} ${Y}NAT FWD TCP  :${NC} ${W}${fwd_disp}${NC}${sp5}${C}Load Balancer:${NC} ${W}${lb_txt}${NC} ${B}│${NC}"
        fi

        echo -e "  ${B}╰────────────────────────────────────────────────────────────────────────────────────────────╯\n"
    done
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r dummy
}

menu_delete_tunnels() {
    while true; do
        draw_mgre_header
        local -a configs=("$CONF_DIR"/*.conf)
        if [ ! -e "${configs[0]}" ]; then
            echo -e "\n  ${Y}● No tunnels configured.${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r _
            return
        fi

        echo -e "\n  ${R}┌─[ DELETE TUNNELS ]${NC}"
        local conf n=0 TYPE TUN_PROTO T_NAME role sel confirm idx
        for conf in "${configs[@]}"; do
            [ -f "$conf" ] || continue
            TUN_PROTO="ipv4"; TYPE=""; T_NAME=""; source "$conf" 2>/dev/null
            n=$((n+1))
            role=$([ "$TYPE" == "1" ] && echo IRAN || echo KHAREJ)
            echo -e "  ${W}${n}${NC} ${DIM}❯${NC} ${Y}${T_NAME}${NC} ${DIM}|${NC} ${C}$(mgre_proto_label "$TUN_PROTO")${NC} ${DIM}|${NC} ${role}"
        done
        echo -e "  ${W}a${NC} ${DIM}❯${NC} Delete ALL tunnels"
        echo -e "  ${W}q${NC} ${DIM}❯${NC} Back"
        echo -ne "\n  ${C}Select tunnel to delete ❯❯ ${NC}"; read -r sel
        sel=$(echo "$sel" | tr -d '\r ')
        [[ "$sel" == "q" || "$sel" == "Q" ]] && return

        if [[ "$sel" == "a" || "$sel" == "A" ]]; then
            echo -ne "  ${R}Delete ALL ${n} tunnels? Type 'yes' to confirm: ${NC}"; read -r confirm
            [ "$confirm" == "yes" ] || continue
            for conf in "${configs[@]}"; do
                [ -f "$conf" ] || continue
                teardown_tunnel "$conf"
                rm -f "$conf"
            done
            rebuild_guard
            echo -e "  ${G}✔ All ${n} tunnels deleted.${NC}"
            sleep 1.5
            continue
        fi

        idx=$(pick_index "$sel" "$n") || { echo -e "  ${R}✖ Invalid selection.${NC}"; sleep 1; continue; }
        conf="${configs[$idx]}"
        [ -f "$conf" ] || { echo -e "  ${R}✖ Tunnel configuration not found.${NC}"; sleep 1; continue; }
        T_NAME=""; source "$conf" 2>/dev/null
        echo -ne "  ${R}Delete tunnel [${T_NAME}]? Type 'yes' to confirm: ${NC}"; read -r confirm
        [ "$confirm" == "yes" ] || continue
        teardown_tunnel "$conf"
        rm -f "$conf"
        rebuild_guard
        echo -e "  ${G}✔ Tunnel [${T_NAME}] deleted successfully.${NC}"
        sleep 1.5
    done
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
    IPT_BIN=ip6tables ipt_delete_tagged mangle FORWARD "MGRE_MSS_${t}"
}

mgre_mtu_limits() { # <proto> -> "min max default"
    case "$1" in
        6to4)      echo "1280 1432 1420" ;;
        gre6)      echo "700 1452 1436" ;;     # 1500 - 40 (IPv6) - 8 (GRE+key)
        ipip4to4)  echo "576 1480 1480" ;;
        ipip4to6)  echo "576 1460 1440" ;;
        ipip6to6)  echo "1280 1460 1440" ;;
        *)         echo "700 1472 1436" ;;
    esac
}

mgre_apply_fwd() {
    local conf="$1"
    local TYPE="" T_NAME="" CORE_SUBNET="" MAX_IPS="0" SYNC_KEY="" FWD_TCP="" FWD_UDP="" LB_MODE="0" TUN_PROTO="ipv4"
    source "$conf" 2>/dev/null
    clean_fwd_rules "$T_NAME"
    [ "$TYPE" == "1" ] || return 0
    [ "$TUN_PROTO" == "ipip6to6" ] && return 0     # IPv6 payload: the NAT forwarder is IPv4-only
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
    ip link del "$T_NAME" >/dev/null 2>&1; ip link del "sit_$T_NAME" >/dev/null 2>&1
    rm -f "$SECURE_TMP/.mgre_lbdead_${T_NAME}"
}

rebuild_guard() {
    ipt_delete_tagged filter INPUT "MGRE_GUARD_HOOK"
    IPT_BIN=ip6tables ipt_delete_tagged filter INPUT "MGRE_GUARD_HOOK"
    iptables -F MGRE_GUARD 2>/dev/null
    ip6tables -F MGRE6_GUARD 2>/dev/null
    if [ ! -f "$GUARD_FLAG" ]; then
        iptables -X MGRE_GUARD 2>/dev/null
        ip6tables -X MGRE6_GUARD 2>/dev/null
        return 0
    fi
    iptables -N MGRE_GUARD 2>/dev/null
    ip6tables -N MGRE6_GUARD 2>/dev/null
    local conf TYPE REMOTE_PUB LOCAL_PUB REMOTE_PUB6 LOCAL_PUB6 REMOTE_IP6 LOCAL_IP6 TUN_PROTO
    local h_ipip4=0 h_gre6=0 h_ip4in6=0 h_ip6in6=0 peers6=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; REMOTE_PUB=""; LOCAL_PUB=""; REMOTE_PUB6=""; LOCAL_PUB6=""; REMOTE_IP6=""; LOCAL_IP6=""; TUN_PROTO="ipv4"; source "$conf" 2>/dev/null
        mgre_endpoints
        if [ "$EP_V6" -eq 1 ]; then
            is_ipv6 "$EP_R" || continue
            ip6tables -A MGRE6_GUARD -s "$EP_R" -j ACCEPT; peers6=1
            case "$TUN_PROTO" in gre6) h_gre6=1 ;; ipip4to6) h_ip4in6=1 ;; ipip6to6) h_ip6in6=1 ;; esac
        else
            is_ipv4 "$EP_R" && iptables -A MGRE_GUARD -s "$EP_R" -j ACCEPT
            [ "$TUN_PROTO" == "ipip4to4" ] && h_ipip4=1
        fi
    done
    iptables -A MGRE_GUARD -j DROP
    iptables -I INPUT 1 -p gre -m comment --comment "MGRE_GUARD_HOOK" -j MGRE_GUARD
    iptables -I INPUT 1 -p 41  -m comment --comment "MGRE_GUARD_HOOK" -j MGRE_GUARD
    [ "$h_ipip4" -eq 1 ] && iptables -I INPUT 1 -p 4 -m comment --comment "MGRE_GUARD_HOOK" -j MGRE_GUARD
    # IPv6 hooks only for the protocols actually used, so unrelated IPv6 tunnels on the host stay untouched
    if [ "$peers6" -eq 1 ]; then
        ip6tables -A MGRE6_GUARD -j DROP
        [ "$h_gre6" -eq 1 ]   && ip6tables -I INPUT 1 -p 47 -m comment --comment "MGRE_GUARD_HOOK" -j MGRE6_GUARD
        [ "$h_ip4in6" -eq 1 ] && ip6tables -I INPUT 1 -p 4  -m comment --comment "MGRE_GUARD_HOOK" -j MGRE6_GUARD
        [ "$h_ip6in6" -eq 1 ] && ip6tables -I INPUT 1 -p 41 -m comment --comment "MGRE_GUARD_HOOK" -j MGRE6_GUARD
    else
        ip6tables -X MGRE6_GUARD 2>/dev/null
    fi
}

mgre_watchdog() {
    local conf TYPE T_NAME CORE_SUBNET CORE_V6 TUN_PROTO MAX_IPS SYNC_KEY LB_MODE FWD_TCP FWD_UDP pair t deadf newdead failf fails
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; CORE_SUBNET=""; CORE_V6=""; TUN_PROTO="ipv4"; MAX_IPS="0"; SYNC_KEY=""; LB_MODE="0"; FWD_TCP=""; FWD_UDP=""
        source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        mgre_core_ips
        if [ ! -d "/sys/class/net/$T_NAME" ]; then
            wd_log "$T_NAME: interface missing, re-applying"; apply_tunnel "$conf"; continue
        fi
        failf="$SECURE_TMP/.mgre_wdfail_${T_NAME}"
        if ! $CORE_PING -c 3 -i 0.3 -W 2 "$CORE_TIP" >/dev/null 2>&1; then
            fails=$(( $(cat "$failf" 2>/dev/null || echo 0) + 1 )); echo "$fails" > "$failf"
            if [ "$fails" -ge 2 ]; then
                wd_log "$T_NAME: peer $CORE_TIP unreachable ${fails}x, re-applying tunnel"; apply_tunnel "$conf"; echo 0 > "$failf"
            fi
            continue
        fi
        echo 0 > "$failf"
        if [ "$TYPE" == "1" ] && [ "$LB_MODE" == "1" ] && [ "$TUN_PROTO" != "ipip6to6" ] && { [ -n "$FWD_TCP" ] || [ -n "$FWD_UDP" ]; }; then
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
    local conf TYPE T_NAME CORE_SUBNET CORE_V6 ENCRYPT TUN_PROTO LOCAL_PUB REMOTE_PUB LOCAL_PUB6 REMOTE_PUB6 LOCAL_IP6 REMOTE_IP6 st lat
    printf "%-16s %-28s %-6s %-8s %-8s %s\n" "TUNNEL" "PEER" "ROLE" "LINK" "PING" "ENC"
    for conf in "$CONF_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        TYPE=""; T_NAME=""; CORE_SUBNET=""; CORE_V6=""; ENCRYPT="0"; TUN_PROTO="ipv4"; LOCAL_PUB=""; REMOTE_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; LOCAL_IP6=""; REMOTE_IP6=""
        source "$conf" 2>/dev/null
        [ -z "$T_NAME" ] && continue
        mgre_endpoints; mgre_core_ips
        lat=$($CORE_PING -c1 -W1 "$CORE_TIP" 2>/dev/null | grep -oP 'time=\K[0-9.]+')
        st=$([ -d "/sys/class/net/$T_NAME" ] && echo UP || echo DOWN)
        lat="${lat:+${lat}ms}"
        printf "%-16s %-28s %-6s %-8s %-8s %s\n" "$T_NAME" "${EP_R:0:28}" "$([ "$TYPE" == "1" ] && echo IR || echo KH)" "$st" "${lat:----}" "$([ "$ENCRYPT" == "1" ] && echo ON || echo OFF)"
    done
}

# ---------------- ADVANCED MENU ACTIONS ----------------
menu_encrypt() {
    select_tunnel_interactive || return
    local ENCRYPT="0" T_NAME="" TYPE="" TUN_PROTO="ipv4"; source "$SELECTED_CONF" 2>/dev/null
    draw_mgre_header
    if [ -z "$(mgre_enc_selector "$TUN_PROTO")" ]; then
        echo -e "\n  ${Y}● IPsec encryption is not supported for $(mgre_proto_label "$TUN_PROTO") tunnels (IPv6-outer IPIP). Use GRE6 instead if you need encryption.${NC}"
        sleep 3; return
    fi
    echo -e "\n  ${DIM}┌─[ IPsec ESP ENCRYPTION: ${W}${T_NAME}${DIM} ]${NC}"
    echo -e "  ${DIM}│${NC} Status : $([ "$ENCRYPT" == "1" ] && echo -e "${G}ENCRYPTED (AES-256-CBC + HMAC-SHA256)${NC}" || echo -e "${R}PLAINTEXT${NC}")"
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
    echo -e "  ${DIM}│${NC} Accepts GRE / IPIP / proto-41 packets ONLY from configured peer IPs (IPv4 + IPv6), drops the rest."
    echo -e "  ${DIM}│${NC} ${Y}Note: blocks any other GRE/6in4/IPIP tunnels on this host that are not managed by MGRE.${NC}"
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
    local T_NAME="" TUN_PROTO="ipv4" LOCAL_PUB="" REMOTE_PUB="" LOCAL_PUB6="" REMOTE_PUB6="" LOCAL_IP6="" REMOTE_IP6="" ENCRYPT="0"; source "$SELECTED_CONF" 2>/dev/null
    mgre_endpoints
    draw_mgre_header
    echo -e "\n  ${C}⟳${NC} ${W}Probing path MTU to ${EP_R} (DF-bit binary search)...${NC}"
    local pmtu; pmtu=$(probe_path_mtu "$EP_R")
    if [ "$pmtu" -eq 0 ]; then echo -e "  ${R}✖ Peer does not answer ICMP. Cannot probe, set MTU manually (option 11).${NC}"; sleep 2.5; return; fi
    local ovh; ovh=$(mgre_overhead "$TUN_PROTO"); [ "$ENCRYPT" == "1" ] && ovh=$((ovh + 64))
    local lim min max; lim=$(mgre_mtu_limits "$TUN_PROTO"); min=${lim%% *}; max=$(echo "$lim" | awk '{print $2}')
    local best=$((pmtu - ovh)); [ "$best" -gt "$max" ] && best=$max; [ "$best" -lt "$min" ] && best=$min
    local mss_ovh=40; [ "$TUN_PROTO" == "ipip6to6" ] && mss_ovh=60
    echo -e "  ${DIM}├─${NC} Path MTU      : ${W}${pmtu}${NC}"
    echo -e "  ${DIM}├─${NC} Tunnel overhead: ${W}${ovh}${NC} bytes"
    echo -e "  ${DIM}└─${NC} Recommended   : ${G}${best}${NC} (MSS $((best - mss_ovh)))"
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

update_available_badge() {
    local remote_v=""
    [ -f "$SECURE_TMP/.mgre_remote_ver" ] && remote_v=$(tr -d '\r\n ' < "$SECURE_TMP/.mgre_remote_ver")
    if [ -n "$remote_v" ] && [ "$remote_v" != "Unknown" ] && [ "$remote_v" != "$MODULE_VERSION" ]; then
        printf '  %b' "${Y}(Update Available: v${remote_v})${NC}"
    fi
}

render_mgre_menu() {
    draw_mgre_header
    echo -e "\n  ${DIM}┌─[ PROVISION & MANAGE ]${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Setup New Tunnel (GRE / GRE6 / IPIP)${NC}"
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
    echo -e "  ${DIM}├─${NC} ${W}19${NC}${DIM}❯${NC} ${G}Instant OTA Update Module${NC} $(update_available_badge)"
    echo -e "  ${DIM}├─${NC} ${W}20${NC}${DIM}❯${NC} ${R}Uninstall MGRE${NC} ${DIM}(Purge All)${NC}"
    echo -e "  ${DIM}│${NC}"
    echo -e "  ${DIM}└─${NC} ${W}0${NC} ${DIM}❯${NC} ${DIM}Return to Main Core${NC}\n"
}

while true; do
    render_mgre_menu > "$SECURE_TMP/.mgre_frame"
    cat "$SECURE_TMP/.mgre_frame"
    LIVE_ROWS=$(( $(wc -l < "$SECURE_TMP/.mgre_frame") )); LIVE_HEADER_FUNC="draw_mgre_header"
    LIVE_MENU_FUNC="render_mgre_menu"; LIVE_FRAME_FILE="$SECURE_TMP/.mgre_frame"
    read_with_refresh "  ${C}MGRE ❯❯ ${NC}" opt
    LIVE_HEADER_FUNC=""; LIVE_MENU_FUNC=""
    opt=$(echo "$opt" | tr -d '\r')
    case $opt in
        1) 
           draw_mgre_header
           echo -e "\n  ${DIM}┌─[ TUNNEL PROTOCOL ]${NC}"
           echo -e "  ${DIM}│${NC}"
           echo -e "  ${DIM}├─${NC} ${W}1${NC} ${DIM}❯${NC} ${C}Standard IPv4 GRE${NC}"
           echo -e "  ${DIM}├─${NC} ${W}2${NC} ${DIM}❯${NC} ${M}6to4 IP6GRE Encapsulation${NC} ${DIM}(IPv6 inside IPv4 sit)${NC}"
           echo -e "  ${DIM}├─${NC} ${W}3${NC} ${DIM}❯${NC} ${M}Direct GRE6 (IPv6 ➔ IPv6)${NC} ${DIM}(ip6gre over public IPv6)${NC}"
           echo -e "  ${DIM}├─${NC} ${W}4${NC} ${DIM}❯${NC} ${G}IPIP4 → IPIP4${NC}"
           echo -e "  ${DIM}├─${NC} ${W}5${NC} ${DIM}❯${NC} ${G}IPIP4 → IPIP6 (IPv4 over IPv6)${NC}"
           echo -e "  ${DIM}├─${NC} ${W}6${NC} ${DIM}❯${NC} ${G}IPIP6 → IPIP6 (IPv6 over IPv6)${NC}"
           echo -e "  ${DIM}│${NC}"
           echo -e "  ${DIM}└─${NC} ${W}q${NC} ${DIM}❯${NC} ${DIM}Cancel and Go Back${NC}\n"
           while true; do echo -ne "  ${C}Select Protocol ❯❯ ${NC}"; read -r proto_choice; [[ "$proto_choice" == "q" ]] && break; [[ "$proto_choice" =~ ^[1-6]$ ]] && break; done
           [[ "$proto_choice" == "q" ]] && continue
           tun_proto="ipv4"
           case "$proto_choice" in 2) tun_proto="6to4";; 3) tun_proto="gre6";; 4) tun_proto="ipip4to4";; 5) tun_proto="ipip4to6";; 6) tun_proto="ipip6to6";; esac

           while true; do echo -ne "  ${C}●${NC} ${W}Server Mode [1:IR | 2:KH | q:Back]: ${NC}"; read -r s_type; [[ "$s_type" == "q" ]] && break; [[ "$s_type" == "1" || "$s_type" == "2" ]] && break; done
           [[ "$s_type" == "q" ]] && continue

           while true; do
               echo -ne "  ${C}●${NC} ${W}Interface Suffix Name (Max 4 chars): ${NC}"; read -r suffix
               suffix=$(echo "$suffix" | tr -dc 'a-zA-Z0-9')
               [[ "$suffix" == "q" ]] && break; [[ -z "$suffix" ]] && continue
               pfx=$(mgre_name_prefix "$tun_proto" "$s_type")
               t_name="${pfx}${suffix}"
               check_len=${#t_name}; [ "$tun_proto" == "6to4" ] && check_len=$((check_len + 4))   # sit_ prefix
               [ "$check_len" -le 15 ] && break
               echo -e "  ${R}● Error: Name too long! Kernel limit is 15 chars.${NC}"
           done
           [[ "$suffix" == "q" ]] && continue
           if [ -f "$CONF_DIR/${t_name}.conf" ]; then echo -e "\n  ${R}● Error: Interface name [${t_name}] already exists!${NC}"; sleep 2; continue; fi

           local_ip=""; local_ip6=""; r_ip=""; r_ip6=""; r_v4=""; core_v6=""; probe_dst=""
           if ! mgre_proto_is_v6 "$tun_proto"; then
               local_ip="$(get_local_ip)"
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Local Public IPv4 [${Y}${local_ip}${W}]: ${NC}"; read -r custom_ip
                   [[ "$custom_ip" == "q" ]] && break
                   custom_ip=$(echo "$custom_ip" | tr -dc '0-9.')
                   if [ -n "$custom_ip" ] && ! is_ipv4 "$custom_ip"; then echo -e "  ${R}✖ Invalid IPv4 address.${NC}"; continue; fi
                   [ -n "$custom_ip" ] && local_ip="$custom_ip"
                   break
               done
               [[ "$custom_ip" == "q" ]] && continue
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IPv4: ${NC}"; read -r r_ip
                   [[ "$r_ip" == "q" ]] && break
                   r_ip=$(echo "$r_ip" | tr -dc '0-9.'); is_ipv4 "$r_ip" && break
                   echo -e "  ${R}✖ Invalid IPv4 address.${NC}"
               done
               [[ "$r_ip" == "q" ]] && continue
               probe_dst="$r_ip"
           else
               local_ip6="$(get_local_ipv6)"
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Local Public IPv6 [${Y}${local_ip6:-none}${W}]: ${NC}"; read -r custom_ip6
                   [[ "$custom_ip6" == "q" ]] && break
                   custom_ip6=$(echo "$custom_ip6" | tr -dc '0-9a-fA-F:'); custom_ip6="${custom_ip6,,}"
                   if [ -n "$custom_ip6" ]; then
                       is_global_ipv6 "$custom_ip6" && { local_ip6="$custom_ip6"; break; }
                       echo -e "  ${R}✖ Invalid IPv6 address (global/ULA only, no link-local).${NC}"; continue
                   fi
                   is_global_ipv6 "$local_ip6" && break
                   echo -e "  ${R}✖ No usable IPv6 detected on this host. Enter its public IPv6 manually.${NC}"
               done
               [[ "$custom_ip6" == "q" ]] && continue
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Remote Endpoint Public IPv6: ${NC}"; read -r r_ip6
                   [[ "$r_ip6" == "q" ]] && break
                   r_ip6=$(echo "$r_ip6" | tr -dc '0-9a-fA-F:'); r_ip6="${r_ip6,,}"
                   is_global_ipv6 "$r_ip6" && break
                   echo -e "  ${R}✖ Invalid IPv6 address.${NC}"
               done
               [[ "$r_ip6" == "q" ]] && continue
               while true; do
                   echo -ne "  ${C}●${NC} ${W}Remote Server IPv4 (for header display, Enter to skip): ${NC}"; read -r r_v4
                   [[ "$r_v4" == "q" ]] && break
                   r_v4=$(echo "$r_v4" | tr -dc '0-9.'); [ -z "$r_v4" ] && break
                   is_ipv4 "$r_v4" && break
                   echo -e "  ${R}✖ Invalid IPv4 address.${NC}"
               done
               [[ "$r_v4" == "q" ]] && continue
               probe_dst="$r_ip6"
           fi

           s_key=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null); [ -z "$s_key" ] && s_key=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
           echo -ne "  ${C}●${NC} ${M}Master Secret Token [Default ${s_key}]: ${NC}"; read -r u_key; [[ "$u_key" == "q" ]] && continue
           u_key=$(echo "$u_key" | tr -dc 'a-zA-Z0-9_=-'); tun_secret=${u_key:-$s_key}

           echo -e "  ${C}⟳${NC} ${W}Detecting a safe tunnel MTU automatically...${NC}"
           cust_mtu=$(auto_mtu_for_gre "$probe_dst" "$tun_proto")

           local_ip6_inner=""; remote_ip6_inner=""
           if [[ "$tun_proto" == "6to4" ]]; then
               hash_str=$(echo -n "${tun_secret}_MHDesign" | sha256sum); pfx_v6="fd${hash_str:0:2}:${hash_str:2:4}:${hash_str:6:4}:${hash_str:10:4}"
               if [[ "$s_type" == "1" ]]; then local_ip6_inner="${pfx_v6}::1"; remote_ip6_inner="${pfx_v6}::2"; else local_ip6_inner="${pfx_v6}::2"; remote_ip6_inner="${pfx_v6}::1"; fi
           elif [[ "$tun_proto" == "ipip6to6" ]]; then
               core_v6=$(mgre_gen_core_v6 "$tun_secret")
           fi

           hash_c=$(echo -n "core_${tun_secret}" | sha256sum); tun_id=$(( 16#${hash_c:0:6} ))
           class_selector=$(( 16#${hash_c:6:2} % 3 )); c1=""; c2=""; c3=""
           if [ "$class_selector" == "0" ]; then c1="10"; c2=$(( (16#${hash_c:8:2} % 254) + 1 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 )); elif [ "$class_selector" == "1" ]; then c1="172"; c2=$(( (16#${hash_c:8:2} % 16) + 16 )); c3=$(( (16#${hash_c:10:2} % 254) + 1 )); else c1="192"; c2="168"; c3=$(( (16#${hash_c:10:2} % 254) + 1 )); fi
           core_sub="${c1}.${c2}.${c3}"
           if grep -q "^TUN_ID=$tun_id$" "$CONF_DIR"/*.conf 2>/dev/null || subnet_in_use "$core_sub" || { [ -n "$core_v6" ] && grep -qx "CORE_V6=${core_v6}" "$CONF_DIR"/*.conf 2>/dev/null; }; then echo -e "  ${R}● Collision: subnet ${core_sub}.x / IPv6 prefix / key already used. Choose a different Token.${NC}"; sleep 2; continue; fi

           conf_path="$CONF_DIR/${t_name}.conf"
           {
             echo "TYPE=$s_type"; echo "LOCAL_PUB=$local_ip"; echo "REMOTE_PUB=$r_ip"; echo "LOCAL_PUB6=$local_ip6"; echo "REMOTE_PUB6=$r_ip6"; echo "REMOTE_V4=$r_v4"; echo "MAX_IPS=0"; echo "SYNC_KEY="; echo "TUN_SECRET=$tun_secret"; echo "T_NAME=$t_name"; echo "TUN_ID=$tun_id"; echo "CORE_SUBNET=$core_sub"; echo "CORE_V6=$core_v6"; echo "TUN_PROTO=$tun_proto"; echo "LOCAL_IP6=$local_ip6_inner"; echo "REMOTE_IP6=$remote_ip6_inner"; echo "FWD_TCP="; echo "FWD_UDP="; echo "LB_MODE=0"; echo "CUSTOM_MTU=$cust_mtu"; echo "ENCRYPT=0";
           } > "$conf_path"
           chmod 600 "$conf_path"
           apply_tunnel "$conf_path"

           if ip link show "$t_name" >/dev/null 2>&1; then
               setup_service
               echo -e "  ${G}● Tunnel [${t_name}] deployed successfully (Protocol: ${tun_proto} | MTU: ${cust_mtu})${NC}"
               pt=$(TYPE="$s_type" TUN_PROTO="$tun_proto" CORE_SUBNET="$core_sub" CORE_V6="$core_v6"; mgre_core_ips; echo "$CORE_PING|$CORE_TIP")
               ping_cmd="${pt%%|*}"; remote_tip="${pt#*|}"
               mgre_proto_is_v6 "$tun_proto" && echo -e "  ${DIM}● IPv6 underlay (${tun_proto}): allow the tunnel protocol over IPv6 in the firewall on BOTH servers (GRE=47, IPIP4>6=4, IPIP6>6=41).${NC}"
               echo -ne "\n  ${C}●${NC} ${W}Run initial ping test to peer now? (y/n): ${NC}"; read -r run_initial_ping; run_initial_ping=$(echo "$run_initial_ping" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
               if [[ "$run_initial_ping" == "y" || "$run_initial_ping" == "yes" ]]; then
                   $ping_cmd -c 4 -W 1 "$remote_tip" 2>&1
               fi

               # Port forwarding is meaningful only on the IRAN/access side when the tunnel payload is IPv4.
               if [[ "$s_type" == "1" && "$tun_proto" != "ipip6to6" ]]; then
                   echo -ne "  ${C}●${NC} ${W}Do you want to configure Port Forwarding / Load Balancer now? (y/n): ${NC}"
                   read -r setup_fwd_now
                   setup_fwd_now=$(echo "$setup_fwd_now" | tr -d '\r ' | tr '[:upper:]' '[:lower:]')
                   if [[ "$setup_fwd_now" == "y" || "$setup_fwd_now" == "yes" ]]; then
                       manage_port_forwarding "$conf_path"
                   fi
               elif [[ "$s_type" == "1" && "$tun_proto" == "ipip6to6" ]]; then
                   echo -e "  ${DIM}● Port Forwarding is skipped: IPIP6→6 carries IPv6 payload and the current forwarder is IPv4/NAT based.${NC}"
               fi
           else
               echo -e "  ${R}✖ Tunnel creation failed. Check kernel support (ip6_gre / ipip / ip6_tunnel), IPv6 routing, and that no other ipip tunnel already uses the same local/remote pair.${NC}"
               rm -f "$conf_path"
           fi
           sleep 2
           ;;

        6) menu_delete_tunnels ;;

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
           LOCAL_PUB=""; REMOTE_PUB=""; LOCAL_PUB6=""; REMOTE_PUB6=""; LOCAL_IP6=""; REMOTE_IP6=""; REMOTE_V4=""; TUN_PROTO="ipv4"; T_NAME=""; source "$SELECTED_CONF" 2>/dev/null
           if mgre_proto_is_v6 "$TUN_PROTO"; then
               echo -ne "  ${C}●${NC} ${W}New Local Public IPv6 [${Y}${LOCAL_PUB6:-$LOCAL_IP6}${W}]: ${NC}"; read -r new_local6
               echo -ne "  ${C}●${NC} ${W}New Remote Public IPv6 [${Y}${REMOTE_PUB6:-$REMOTE_IP6}${W}]: ${NC}"; read -r new_remote6
               echo -ne "  ${C}●${NC} ${W}New Remote Server IPv4 for header [${Y}${REMOTE_V4}${W}]: ${NC}"; read -r new_rv4
               new_rv4=$(echo "$new_rv4" | tr -dc '0-9.')
               if [ -n "$new_rv4" ] && ! is_ipv4 "$new_rv4"; then echo -e "  ${R}✖ Invalid IPv4 address.${NC}"; sleep 1.5; continue; fi
               new_local6=$(echo "$new_local6" | tr -dc '0-9a-fA-F:'); new_local6="${new_local6,,}"
               new_remote6=$(echo "$new_remote6" | tr -dc '0-9a-fA-F:'); new_remote6="${new_remote6,,}"
               if [ -n "$new_local6" ] && ! is_global_ipv6 "$new_local6"; then echo -e "  ${R}✖ Invalid local IPv6.${NC}"; sleep 1.5; continue; fi
               if [ -n "$new_remote6" ] && ! is_global_ipv6 "$new_remote6"; then echo -e "  ${R}✖ Invalid remote IPv6.${NC}"; sleep 1.5; continue; fi
               xfrm_clear "$T_NAME"
               [ -n "$new_local6" ] && set_conf_var "$SELECTED_CONF" LOCAL_PUB6 "$new_local6"
               [ -n "$new_remote6" ] && set_conf_var "$SELECTED_CONF" REMOTE_PUB6 "$new_remote6"
               [ -n "$new_rv4" ] && set_conf_var "$SELECTED_CONF" REMOTE_V4 "$new_rv4"
           else
               echo -ne "  ${C}●${NC} ${W}New Local Public IPv4 [${Y}${LOCAL_PUB}${W}]: ${NC}"; read -r new_local
               echo -ne "  ${C}●${NC} ${W}New Remote Public IPv4 [${Y}${REMOTE_PUB}${W}]: ${NC}"; read -r new_remote
               new_local=$(echo "$new_local" | tr -dc '0-9.'); new_remote=$(echo "$new_remote" | tr -dc '0-9.')
               if [ -n "$new_local" ] && ! is_ipv4 "$new_local"; then echo -e "  ${R}✖ Invalid local IPv4.${NC}"; sleep 1.5; continue; fi
               if [ -n "$new_remote" ] && ! is_ipv4 "$new_remote"; then echo -e "  ${R}✖ Invalid remote IPv4.${NC}"; sleep 1.5; continue; fi
               xfrm_clear "$T_NAME"
               [ -n "$new_local" ] && set_conf_var "$SELECTED_CONF" LOCAL_PUB "$new_local"
               [ -n "$new_remote" ] && set_conf_var "$SELECTED_CONF" REMOTE_PUB "$new_remote"
           fi
           apply_tunnel "$SELECTED_CONF"
           echo -e "  ${G}● Public endpoints updated and applied.${NC}"; sleep 1.5 ;;

        9)
           select_tunnel_interactive || continue
           draw_mgre_header
           TUN_SECRET=""; T_NAME=""; TUN_PROTO="ipv4"; source "$SELECTED_CONF" 2>/dev/null
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
               [ "$TUN_PROTO" == "ipip6to6" ] && set_conf_var "$SELECTED_CONF" CORE_V6 "$(mgre_gen_core_v6 "$new_tok")"
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
           T_NAME=""; TUN_PROTO="ipv4"; TYPE=""; source "$SELECTED_CONF" 2>/dev/null
           echo -ne "  ${C}●${NC} ${W}New Interface Suffix (Current: ${Y}$(get_pure_tun_name "$T_NAME")${W}): ${NC}"; read -r new_suffix
           new_suffix=$(echo "$new_suffix" | tr -dc 'a-zA-Z0-9')
           if [ -n "$new_suffix" ]; then
               pfx=$(mgre_name_prefix "$TUN_PROTO" "$TYPE")
               new_t_name="${pfx}${new_suffix}"
               check_len=${#new_t_name}; [ "$TUN_PROTO" == "6to4" ] && check_len=$((check_len + 4))   # sit_ prefix
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
