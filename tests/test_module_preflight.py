from pathlib import Path
import subprocess,re,tempfile
root=Path(__file__).resolve().parents[1]
def fn(module,name):
 s=(root/module).read_text();m=re.search(r'^'+name+r'\(\) \{.*?^\}',s,re.M|re.S);assert m,name;return m.group()
def run(name,body):
 p=subprocess.run(['bash','-c',f'source {root}/core/common.sh\n'+body],capture_output=True,text=True,timeout=10)
 assert p.returncode==0,(name,p.stdout,p.stderr);print('PASS',name)
with tempfile.TemporaryDirectory() as temp:
 # A foreign port aborts before any existing GRE/VXLAN rules or interface change.
 for mod,ap,fw,identity in [('mgre','apply_tunnel','mgre_apply_fwd','T_NAME=gre_test'),('mxlan','apply_fabric','mxlan_apply_fwd','VX_NAME=vx_test\nBR_NAME=br_test')]:
  conf=Path(temp)/f'{mod}.conf';conf.write_text('TYPE=1\n'+identity+'\nFWD_TCP=443\nFWD_UDP=53\n')
  funcs='\n'.join(fn('tunnels/'+mod+'.sh',n) for n in [ap,fw])
  run(mod+' apply preflight preserves runtime',f'''{funcs}
mt_validate_tunnel_conf() {{ :; }}; mt_validate_conf() {{ :; }}
mt_guard_ports() {{ echo guard >> {temp}/guards; return 1; }}
clean_fwd_rules() {{ touch {temp}/BAD_CLEAN; }}; ip() {{ touch {temp}/BAD_IP; }}
{ap} {conf}; rc=$?; [ "$rc" = 1 ] && [ ! -e {temp}/BAD_CLEAN ] && [ ! -e {temp}/BAD_IP ]
''')
  run(mod+' forwarding preflight preserves rules',f'''{funcs}
mt_validate_conf() {{ :; }}; mt_guard_ports() {{ return 1; }}
clean_fwd_rules() {{ touch {temp}/BAD_CLEAN; }}
{fw} {conf}; rc=$?; [ "$rc" = 1 ] && [ ! -e {temp}/BAD_CLEAN ]
''')
 # Rathole config generation may read current metadata, but cannot truncate TOML
 # after guard rejection. A client must not claim local ownership of remote port.
 d=Path(temp)/'rat1';d.mkdir();meta=d/'meta.conf';toml=d/'config.toml'
 meta.write_text('TYPE=1\nLINK_PORT=8080\nTCP_PORTS=443\nUDP_PORTS=53\nBIND_HOST=0.0.0.0\nTOKEN=abc\n');toml.write_text('KEEP')
 funcs='\n'.join(fn('tunnels/mrathole.sh',n) for n in ['rat_guard_values','generate_toml'])
 run('Rathole abort preserves TOML',f'''{funcs}
CONF_DIR={temp}; validate_forward_ports() {{ mt_validate_port_list "$1" 0; }}
mt_guard_ports() {{ return 1; }}
generate_toml rat1; rc=$?; [ "$rc" = 1 ] && [ "$(cat {toml})" = KEEP ]
''')
 run('Rathole client remote port not checked',f'''{funcs}
mt_guard_ports() {{ touch {temp}/BAD_REMOTE;return 1; }}
rat_guard_values rat1 2 8080 443 53 && [ ! -e {temp}/BAD_REMOTE ]
''')
 # Backhaul final writer guards before committing new TOML/meta.
 bh=Path(temp)/'bh';bh.mkdir();(bh/'bh1.meta').write_text('BIND_HOST=0.0.0.0\nFORWARDER=backhaul\n');(bh/'bh1.toml').write_text('KEEP')
 funcs='\n'.join(fn('tunnels/mbackhaul.sh',n) for n in ['validate_bh_ports','bh_write_config_locked','bh_expanded_ports','bh_forward_chain'])
 run('Backhaul guards before config commit',f'''{funcs}
CONF_DIR={bh}; bh_load_options() {{ :; }}; bh_meta_value() {{ mt_read_kv "$2" "$1"; }}
mt_guard_ports() {{ return 1; }}
bh_write_config_locked bh1 1 tcp 8443 0.0.0.0 abc 443 true 0.0.0.0 backhaul; rc=$?
[ "$rc" = 1 ] && [ "$(cat {bh}/bh1.toml)" = KEEP ] && ! grep -q PORTS {bh}/bh1.meta
''')
 # Paqet range expansion, including numeric normalization and raw-reservation owner.
 run('Paqet ranges expanded correctly','[ "$(mt_expand_port_list 0080,100:102 | paste -sd,)" = 80,100,101,102 ]')
 # Header data reads only the selected module config directory and full IPv6.
 for kind,mod,identity,proto in [('gre','mgre','T_NAME=gre1','TUN_PROTO=gre6'),('vxlan','mxlan','VX_NAME=vx1\nBR_NAME=br1','FAB_PROTO=ipv6')]:
  confdir=Path(temp)/mod;confdir.mkdir();(confdir/'t.conf').write_text(identity+'\n'+proto+'\nREMOTE_PUB6=2001:db8::1234\n')
  run(mod+' header module filter + IPv6',f'''CONF_DIR={confdir};SECURE_TMP={temp}
mgre_proto_is_v6() {{ [ "$1" = gre6 ]; }}; ip() {{ return 1; }}
r=$(mt_interface_header_rows {kind}); [[ "$r" == *2001:db8::1234* && "$r" != *bh1* && "$r" != *rat1* ]]
''')
print('TOTAL 10 integration checks')
