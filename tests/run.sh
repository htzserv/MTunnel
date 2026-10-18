#!/usr/bin/env bash
# MTunnel regression tests. Run before every release:  bash tests/run.sh
# No root, no network, no real iptables/ss/systemctl: PATH points at tests/shims.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/tests/shims:$PATH"
export MT_FIX; MT_FIX=$(mktemp -d); trap 'rm -rf "$MT_FIX"' EXIT
export SECURE_TMP="$MT_FIX/tmp"; mkdir -p "$SECURE_TMP" "$MT_FIX/srv/core"
export MTUNNEL_MIRROR_BASE=https://mirror.test/m MTUNNEL_GITHUB_BASE=https://raw.githubusercontent.com/test/test/main
R=; G=; Y=; C=; M=; B=; W=; DIM=; NC=
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n         expected: [%s]\n         got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }        # name expected actual
has()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "contains: $2" "$3"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
reset_fix() { rm -f "$MT_FIX"/*.txt "$MT_FIX"/ipt.log; : > "$MT_FIX/ipt.log"; }

section "syntax (bash -n)"
for f in main.sh mporter.sh install.sh core/common.sh tunnels/*.sh; do
    if bash -n "$ROOT/$f" 2>/dev/null; then ok "$f"; else bad "$f" "no syntax error" "syntax error"; fi
done

# shellcheck disable=SC1091
source "$ROOT/core/common.sh" || { echo "cannot load common.sh"; exit 1; }
mt_unit_pids() { cat "$MT_FIX/unit_pids.txt" 2>/dev/null; }     # no real cgroups in tests

section "port lists"
reset_fix; echo 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' > "$MT_FIX/ss_listen.txt"
eq "sanitize keeps ports and ranges"        "80,443,1000:2000" "$(mt_sanitize_ports '80, 443,1000:2000' tcp)"
eq "sanitize refuses SSH port range (tcp)"  "80"               "$(mt_sanitize_ports '20:30,80' tcp 2>/dev/null)"
eq "sanitize allows it for udp"             "20:30,80"         "$(mt_sanitize_ports '20:30,80' udp)"
mt_sanitize_ports 99999 tcp >/dev/null 2>&1; eq "sanitize rejects 99999" 1 $?
mt_sanitize_ports 'abc' tcp >/dev/null 2>&1;  eq "sanitize rejects text"  1 $?
eq "merge de-duplicates"   "80,443,8080" "$(mt_merge_ports '80,443' '443,8080')"
eq "remove drops a port"   "80,8080"     "$(mt_remove_ports '80,443,8080' 443)"
eq "subtract splits a range" "100:101,103" "$(mt_ports_subtract '100:103' '102')"
eq "compact merges runs"   "80-82, 90"   "$(mt_ports_compact '80 81 82 90')"
mt_port_in_spec 1500 '80,1000:2000'; eq "in_spec range hit"  0 $?
mt_port_in_spec 2500 '80,1000:2000'; eq "in_spec range miss" 1 $?

section "forward-port conflicts"
reset_fix
cat > "$MT_FIX/ss_listen.txt" <<'X'
tcp LISTEN 0 128 0.0.0.0:8099 0.0.0.0:* users:(("web",pid=111,fd=3))
tcp LISTEN 0 128 127.0.0.1:8098 0.0.0.0:* users:(("local",pid=112,fd=3))
udp UNCONN 0 0 [::]:5353 [::]:* users:(("avahi",pid=113,fd=3))
X
cat > "$MT_FIX/nat.txt" <<'X'
-A PREROUTING -p tcp -m tcp --dport 7000:7010 -m comment --comment "OTHER_FWD" -j DNAT --to-destination 10.0.0.2
-A PREROUTING -p tcp -m tcp --dport 7500 -m comment --comment "SELF_FWD" -j DNAT --to-destination 10.0.0.2
X
eq "public listener inside a range is a conflict" "tcp/8099 " "$(mt_fwd_conflicts 8090:8100 '' SELF_FWD)"
eq "loopback-only listener is ignored"            ""          "$(mt_fwd_conflicts 8098 '' SELF_FWD)"
eq "udp listener detected"                        "udp/5353 " "$(mt_fwd_conflicts '' 5353 SELF_FWD)"
eq "other tunnel's DNAT rule is a conflict"       "tcp/7002 tcp/7003 " "$(mt_fwd_conflicts 7002:7003 '' SELF_FWD)"
eq "own DNAT rule is not a conflict"              ""          "$(mt_fwd_conflicts 7500 '' SELF_FWD)"
mt_fwd_conflict_refresh t1 8099 '' SELF_FWD; mt_fwd_conflict_flag t1; eq "marker set on conflict" 0 $?
mt_fwd_conflict_refresh t1 9999 '' SELF_FWD; mt_fwd_conflict_flag t1; eq "marker cleared when fixed" 1 $?

section "NAT rule builder"
reset_fix
mt_build_fwd_rules TAG_X gre0 "80,443" "53" 0 /dev/null 10.9.9.2; eq "build returns 0" 0 $?
eq "3 rules per port (DNAT+MASQ+FWD) x 3 ports" 9 "$(grep -c '^-w 5 .*-A' "$MT_FIX/ipt.log")"
has "DNAT excludes traffic from the tunnel itself" "! -i gre0" "$(grep DNAT "$MT_FIX/ipt.log" | head -1)"
has "rules are tagged" "--comment TAG_X" "$(head -1 "$MT_FIX/ipt.log")"
reset_fix; IPT_FAIL_AT=4 mt_build_fwd_rules TAG_Y gre0 "80,443" "" 0 /dev/null 10.9.9.2; eq "failed rule -> build returns 1" 1 $?
has "failure triggers rollback of the tag" "-t nat -L PREROUTING" "$(tail -3 "$MT_FIX/ipt.log")"
reset_fix; mt_build_fwd_rules TAG_Z gre0 "80" "" 0 /dev/null "not-an-ip"; eq "invalid target IP rejected" 1 $?

section "link state & reasons"
reset_fix; echo 500 > "$MT_FIX/unit_pids.txt"
cat > "$MT_FIX/ss_established.txt" <<'X'
0 0 10.0.0.1:443 5.6.7.8:50000 users:(("rathole",pid=500,fd=7))
	 cubic rtt:20/5 lastrcv:183000
0 0 10.0.0.1:444 9.9.9.9:41000 users:(("rathole",pid=500,fd=8))
	 cubic rtt:20/5 lastrcv:900
X
eq "stale socket is NOT a live link"      ""        "$(mt_unit_live_peer u@t 443)"
eq "recent socket is a live link"         "9.9.9.9" "$(mt_unit_live_peer u@t 444)"
eq "reason: stale socket"                 "STALE 3m" "$(mt_unit_link_reason u@t 1 443)"
eq "reason: live link has none"           ""        "$(mt_unit_link_reason u@t 1 444)"
eq "reason: server without socket"        "NO CLIENT" "$(mt_unit_link_reason u@t 1 555)"
eq "reason: client without socket"        "NO LINK"   "$(mt_unit_link_reason u@t 0 555)"
echo "u@t" > "$MT_FIX/active.txt"
echo "2026-10-18T10:00:01+0000 ERROR invalid token from 1.2.3.4" > "$MT_FIX/journal.txt"
has "journal: bad token"   "BAD TOKEN"   "$(mt_unit_journal_hint u@t)"
echo "listen tcp 0.0.0.0:443: bind: address already in use" > "$MT_FIX/journal.txt"
has "journal: port in use" "PORT IN USE" "$(mt_unit_journal_hint u@t)"
echo "dial tcp 1.2.3.4:443: connect: connection refused" > "$MT_FIX/journal.txt"
has "journal: refused"     "CONN REFUSED" "$(mt_unit_journal_hint u@t)"
has "stopped unit is reported" "SERVICE STOPPED" "$(mt_link_why not-running 1 443)"
has "combined reason"      "NO CLIENT · CONN REFUSED" "$(mt_link_why u@t 1 555)"

section "shared helpers used by mporter / dashboards"
reset_fix; echo 'tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=812,fd=6))' > "$MT_FIX/ss_listen.txt"
has "holder label names the process" "nginx" "$(mt_port_holder_label tcp 8080)"
has "holder label has the PID"       "PID 812" "$(mt_port_holder_label tcp 8080)"
mt_port_holder_label tcp 9 >/dev/null; eq "free port has no holder" 1 $?
reset_fix; echo 500 > "$MT_FIX/unit_pids.txt"
printf '%s\n' "ESTAB 0 0 10.0.0.1:443 5.6.7.8:50000 users:((\"bh\",pid=500,fd=7))" "	 cubic rtt:23.4/5 lastrcv:900" > "$MT_FIX/ss_established.txt"
cp "$MT_FIX/ss_established.txt" "$MT_FIX/ss_all.txt"
section "heartbeat-based liveness limit"
export MTUNNEL_TEST_ROOT="$MT_FIX/root"; mkdir -p "$MTUNNEL_TEST_ROOT/etc/mrathole/tunnels/r1" "$MTUNNEL_TEST_ROOT/etc/mbackhaul/tunnels"
printf '[server]\nheartbeat_interval = 30\n' > "$MTUNNEL_TEST_ROOT/etc/mrathole/tunnels/r1/config.toml"
printf 'heartbeat = 20\nchannel_size = 4096\n' > "$MTUNNEL_TEST_ROOT/etc/mbackhaul/tunnels/b1.toml"
printf 'heartbeat = 0\n' > "$MTUNNEL_TEST_ROOT/etc/mbackhaul/tunnels/b0.toml"
eq "rathole 30 s heartbeat -> 95 s limit"      95000  "$(mt_unit_max_idle mrathole@r1)"
eq "backhaul 20 s heartbeat -> 65 s limit"     65000  "$(mt_unit_max_idle mbackhaul@b1)"
eq "heartbeat disabled -> legacy 150 s"        150000 "$(mt_unit_max_idle mbackhaul@b0)"
eq "no config -> legacy 150 s"                 150000 "$(mt_unit_max_idle mbackhaul@nope)"
eq "engine without heartbeat -> legacy 150 s"  150000 "$(mt_unit_max_idle mgre@x)"
cat > "$MT_FIX/ss_established.txt" <<'X'
0 0 10.0.0.1:443 5.6.7.8:50000 users:(("bh",pid=500,fd=7))
	 cubic rtt:20/5 lastrcv:100000
X
echo 500 > "$MT_FIX/unit_pids.txt"
eq "100 s silent: alive under a 125 s limit"   "5.6.7.8" "$(mt_unit_live_peer mbackhaul@zz 443)"
eq "100 s silent: stale under a 65 s limit"    ""        "$(mt_unit_live_peer mbackhaul@b1 443)"
eq "reason shows the real silence"             "STALE 1m" "$(mt_unit_link_reason mbackhaul@b1 1 443)"
unset MTUNNEL_TEST_ROOT

section "download integrity (SHA256SUMS)"
reset_fix; mkdir -p "$MT_FIX/srv/core"
echo "good" > "$MT_FIX/srv/core/a.sh"; echo "unlisted" > "$MT_FIX/srv/b.sh"
( cd "$MT_FIX/srv" && sha256sum core/a.sh > SHA256SUMS )
rm -f "$SECURE_TMP"/.mt_sums_*
mt_download https://mirror.test/m/core/a.sh "$MT_FIX/o1" 2>/dev/null; eq "listed + matching file installs" "good" "$(cat "$MT_FIX/o1" 2>/dev/null)"
echo "evil" > "$MT_FIX/srv/core/a.sh"; rm -f "$SECURE_TMP"/.mt_sums_*
mt_download "https://mirror.test/m/core/a.sh?t=1" "$MT_FIX/o2" 2>/dev/null; eq "tampered file is refused" 1 $?
[ ! -e "$MT_FIX/o2" ]; eq "…and nothing is written" 0 $?
echo "new good" > "$MT_FIX/srv/core/a.sh"; ( cd "$MT_FIX/srv" && sha256sum core/a.sh > SHA256SUMS )
mt_download https://mirror.test/m/core/a.sh "$MT_FIX/o3" 2>/dev/null; eq "stale SUMS cache is refreshed once" "new good" "$(cat "$MT_FIX/o3" 2>/dev/null)"
mt_download https://mirror.test/m/b.sh "$MT_FIX/o4" 2>/dev/null; eq "unlisted file passes (compat)" "unlisted" "$(cat "$MT_FIX/o4" 2>/dev/null)"
MTUNNEL_REQUIRE_SUMS=1 mt_download https://mirror.test/m/b.sh "$MT_FIX/o5" 2>/dev/null; eq "REQUIRE_SUMS refuses unlisted" 1 $?
mt_download http://mirror.test/m/b.sh "$MT_FIX/o6" 2>/dev/null; eq "plain http refused" 1 $?

section "release files"
if [ -f "$ROOT/SHA256SUMS" ]; then
    ( cd "$ROOT" && sha256sum -c SHA256SUMS --quiet 2>/dev/null ); eq "SHA256SUMS matches the tree (run tools/make-sums.sh)" 0 $?
else bad "SHA256SUMS present" "file exists" "missing (run tools/make-sums.sh)"; fi
ver=$(tr -d '[:space:]' < "$ROOT/VERSION"); cv=$(sed -n 's/^MTUNNEL_RELEASE_VERSION="\(.*\)"/\1/p' "$ROOT/core/common.sh")
eq "VERSION equals MTUNNEL_RELEASE_VERSION" "$ver" "$cv"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
