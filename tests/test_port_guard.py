from pathlib import Path
import subprocess, tempfile, os, re, pty, select, time, json
ROOT=Path(__file__).resolve().parents[1];CORE=ROOT/'core/common.sh'
passed=0

def test(name,code,success=True,contains=None):
 global passed
 r=subprocess.run(['bash','-c',f'source {CORE}\nMTUNNEL_TEST_ROOT={TMP}\n'+code],text=True,capture_output=True,timeout=12)
 assert (r.returncode==0)==success,(name,r.returncode,r.stdout,r.stderr)
 if contains: assert contains in r.stdout+r.stderr,(name,r.stdout,r.stderr)
 passed+=1;print('PASS',name)

with tempfile.TemporaryDirectory() as TMP:
 sockets='''tcp LISTEN 0 128 0.0.0.0:4443 0.0.0.0:* users:(("demo",pid=987654,fd=3))
udp UNCONN 0 0 [2001:db8::1]:5353 [::]:* users:(("demo",pid=987655,fd=3))'''
 mock=f'''mt_socket_snapshot() {{ cat <<'DATA'
{sockets}
DATA
}}
mt_nat_snapshot() {{ :; }}
'''
 test('valid empty and ranges','mt_validate_port_list "" 0 && mt_validate_port_list "0080,10000:10100" 0')
 for v in ['0','65536','80,80','100:80','12;id','80,,90']:
  test('invalid '+v,f'mt_validate_port_list {json.dumps(v)} 0',False)
 test('IPv4 TCP detected',mock+'mt_guard_ports 4443 tcp',False,'PID      : 987654')
 test('IPv6 UDP detected',mock+'mt_guard_ports 5353 udp',False,'PID      : 987655')
 test('same number different protocol is allowed',mock+'mt_guard_ports 5353 tcp')
 test('range intersection detects listener',mock+'mt_guard_ports 4400:4500 tcp',False,'Port     : 4443')
 test('full free range cheap',mock+'mt_guard_ports 1:4000 tcp')
 test('exact own unit is ignored',mock+'mt_pid_unit() { echo mrathole@demo.service; }; mt_guard_ports 4443 tcp mrathole@demo.service')
 test('other instance is NOT ignored',mock+'mt_pid_unit() { echo mrathole@other.service; }; mt_guard_ports 4443 tcp mrathole@demo.service',False,'mrathole@other.service')
 test('owned port list cannot bypass another process',mock+'MT_PORT_OWNER=mrathole@demo.service; mt_pid_unit() { echo nginx.service; }; mt_validate_port_list 4443 1 tcp 4443',False,'nginx.service')
 test('missing inspector fails closed','mt_socket_snapshot() { return 1; }; mt_guard_ports 443 tcp',False)
 test('unknown PID fails closed',mock.replace('users:(("demo",pid=987654,fd=3))','')+'mt_guard_ports 4443 tcp',False,'PID unavailable')
 nat='iptables-save|-A PREROUTING -p tcp -m tcp --dport 8000:8100 -m comment --comment "MGRE_FWD_gre1" -j DNAT --to-destination 10.1.1.2'
 mocknat='mt_socket_snapshot() { :; }; mt_nat_snapshot() { cat <<\'DATA\'\n'+nat+'\nDATA\n}\n'
 test('NAT range blocks without socket',mocknat+'mt_guard_ports 8050 tcp',False,'MGRE_FWD_gre1')
 test('own NAT ignored',mocknat+'mt_guard_ports 8050 tcp MGRE_FWD_gre1')
 test('NAT range intersect another range',mocknat+'mt_guard_ports 8090:9000 tcp',False,'Port     : 8090')
 test('NAT other protocol allowed',mocknat+'mt_guard_ports 8050 udp')
 test('native forward to another range allowed',mocknat+'mt_guard_ports 9000:9100 tcp')
 test('NAT inspection failure aborts','mt_socket_snapshot() { :; }; mt_nat_snapshot() { return 1; }; mt_guard_ports 443 tcp',False)
 # Verify reachability: hooked custom chains count; orphan chains do not.
 bindir=Path(TMP)/'bin';bindir.mkdir()
 fake=bindir/'iptables-save';fake.write_text('''#!/bin/bash
cat <<'EOF'
*nat
-A PREROUTING -j MY_CHAIN
-A MY_CHAIN -p tcp --dport 7000 -j REDIRECT --to-ports 9000
-A ORPHAN -p tcp --dport 7001 -j REDIRECT --to-ports 9001
COMMIT
EOF
''');fake.chmod(0o755)
 fake6=bindir/'ip6tables-save';fake6.write_text('#!/bin/bash\nexit 0\n');fake6.chmod(0o755)
 test('NAT custom chain reachability',f'PATH={bindir}:$PATH; n=$(mt_nat_snapshot); [[ "$n" == *"7000"* && "$n" != *"7001"* ]]')
 raw=Path(TMP)/'etc/paqet';raw.mkdir(parents=True);(raw/'pq1.meta').write_text('ROLE=1\nTUN_PORT=8888\n')
 free='mt_socket_snapshot() { :; }; mt_nat_snapshot() { :; }; '
 test('Paqet raw reservation detected',free+'mt_guard_ports 8888 tcp',False,'Paqet raw listener')
 test('Paqet own reservation ignored',free+'mt_guard_ports 8888 tcp mpaqet@pq1.service')
 test('Paqet raw TCP does not reserve UDP',free+'mt_guard_ports 8888 udp')
 # Actual PTY decisions. Only a disposable sleep started by this test is signalled.
 for answer in ['n','y']:
  dummy=subprocess.Popen(['sleep','60'])
  try:
   comm='sleep';pid=dummy.pid
   script=f'''source {CORE}
MTUNNEL_TEST_ROOT={TMP}; MT_PORT_INTERACTIVE=1
mt_nat_snapshot() {{ :; }}
mt_pid_unit() {{ return 1; }}
cat() {{ if [ "$1" = /proc/{pid}/comm ]; then echo sleep; else command cat "$@"; fi; }}
mt_socket_snapshot() {{
 if kill -0 {pid} 2>/dev/null; then
  echo 'tcp LISTEN 0 1 0.0.0.0:4443 0.0.0.0:* users:(("sleep",pid={pid},fd=3))'
 fi
}}
mt_guard_ports 4443 tcp; echo RESULT=$?
'''
   master,slave=pty.openpty();proc=subprocess.Popen(['bash','-c',script],stdin=slave,stdout=slave,stderr=slave);os.close(slave)
   buf=b'';sent=False;deadline=time.time()+8
   while time.time()<deadline:
    dummy.poll()
    if select.select([master],[],[],.1)[0]:
     try:chunk=os.read(master,65536)
     except OSError:break
     if not chunk:break
     buf+=chunk
     if b'[y/N]' in buf and not sent:os.write(master,(answer+'\n').encode());sent=True
    if proc.poll() is not None:break
   proc.wait(timeout=3);os.close(master);out=buf.decode()
   if answer=='n': assert sent and dummy.poll() is None and 'RESULT=1' in out,out
   else:
    dummy.wait(timeout=3);assert dummy.returncode==-15 and 'RESULT=0' in out,out
   passed+=1;print('PASS PTY answer',answer)
  finally:
   if dummy.poll() is None:dummy.terminate();dummy.wait()
 # Header widths, colors and expanded IPv6 preserved at narrow/wide sizes.
 for cols in [40,80,120,132,160]:
  ip6='2001:0db8:1234:5678:9abc:def0:1234:5678'
  code=f'''source {CORE}
B='\\033[1;34m';G='\\033[1;32m';R='\\033[1;31m';C='\\033[0;36m';W='\\033[1;37m';M='\\033[1;35m';Y='\\033[1;33m';DIM='\\033[2;37m';NC='\\033[0m'
SECURE_TMP={TMP}; HEADER_LIVE=1
get_local_ip() {{ echo 192.0.2.10; }};get_local_ipv6() {{ echo {ip6}; }}
tput() {{ echo {cols}; }}; systemctl() {{ return 1; }}
mt_module_header 'MBackhaul Core v1.1.4' '1|bh_iran1|{ip6}|12ms|0|1h 02m|ACT' BH
'''
  r=subprocess.run(['bash','-c',code],capture_output=True,text=True,timeout=5);assert r.returncode==0,r.stderr
  out=re.sub(r'\x1b\[[0-9;]*[mK]','',r.stdout)
  lines=[x for x in out.splitlines() if x.strip()]
  assert all(len(x)==len(lines[0]) for x in lines),(cols,[(len(x),x) for x in lines])
  # narrow lines may wrap: flatten the interior to compare full address
  interior=''.join(x.strip().strip('│').strip() for x in lines)
  assert ip6 in interior,(cols,out)
  assert 'iran1' in out and 'No GRE' not in out
  Path(TMP,f'header-{cols}.txt').write_text(out)
  passed+=1;print('PASS header width',cols)
 print('TOTAL',passed)
