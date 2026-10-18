"""Main and module headers must share three content rows and ANSI colors."""
from pathlib import Path
import re, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
 d=Path(tmp)
 (d/'.main_sys_stats').write_text('8|4|767M|7.6G|9|446 KB/s|364 KB/s|ON\n')
 (d/'.main_tun_stats').write_text('BH|tr1|85.9.105.101|OFF|38ms|0|fixture|CLI\n')
 base=f'''source {root}/core/common.sh
B='\\033[1;34m';G='\\033[1;32m';Y='\\033[1;33m';R='\\033[1;31m';C='\\033[0;36m';M='\\033[1;35m';W='\\033[1;37m';DIM='\\033[2;37m';NC='\\033[0m'
MODULE_VERSION=1.1.4;SECURE_TMP={d};HEADER_LIVE=1
get_local_ip() {{ echo 45.92.219.227; }};get_local_ipv6() {{ echo 2a12:bec4:1d40:7ca0::1; }}
tput() {{ echo 160; }};sysctl() {{ echo cubic; }};systemctl() {{ return 1; }}
get_iface_uptime_pure() {{ echo '1h 06m'; }}
'''
 def render(code):
  r=subprocess.run(['bash','-c',base+code],capture_output=True,text=True,check=True)
  return r.stdout
 main=render('mt_main_dashboard_header')
 for tag,title in [('GRE','MGRE Core'),('VXLAN','MXLAN Core'),('RAT','MRathole Core'),('BH','MBackhaul Core'),('PAQET','MPaqet Core')]:
  module=render(f'mt_module_header "{title} v1.1.4" "1|tr1|85.9.105.101|38ms|0|1h 06m|CLI" {tag}')
  plain=re.sub(r'\x1b\[[0-9;]*[mK]','',module)
  lines=[line for line in plain.splitlines() if line.strip()]
  assert len([line for line in lines if line.startswith('  │')])==3,plain
  assert len([line for line in lines if line.startswith('  ├')])==2,plain
  assert len(set(map(len,lines)))==1,plain
  # Entire CPU/statistics row and first-row status use identical ANSI sequences.
  mainrows=[line for line in main.splitlines() if 'CPU:' in line or 'Cores:' in line]
  modrows=[line for line in module.splitlines() if 'CPU:' in line or 'Cores:' in line]
  assert mainrows==modrows
  assert '\x1b[2;37mPeer:\x1b[0m \x1b[1;35m85.9.105.101' in module
  assert '\x1b[2;37mPing:\x1b[0m\x1b[1;33m38ms' in module
  assert '\x1b[2;37mLoss:\x1b[0m\x1b[1;32m0%' in module
  assert '\x1b[2;37mUp:\x1b[0m \x1b[1;37m1h 06m' in module
  print('PASS three-row layout and main palette:',tag)
 print('TOTAL 5 header parity checks')
