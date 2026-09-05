"""CIDR policy and actual network phase executed only in a temporary mocked host."""
import copy
import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import network_config as nc
import yaml

LINKS = [{'ifname':'ens160','link_type':'ether','address':'02:00:00:00:00:01'},
         {'ifname':'docker0','link_type':'ether','linkinfo':{'info_kind':'bridge'},'address':'02:00:00:00:00:02'}]
ADDRS = [{'ifname':'ens160','addr_info':[{'family':'inet','local':'192.168.50.100','prefixlen':24,'scope':'global'}]}]
ROUTES = [{'dst':'default','dev':'ens160','gateway':'192.168.50.1'}]


class NetworkPolicyTests(unittest.TestCase):
    def test_cidr_and_legacy_compatibility(self):
        self.assertEqual(nc.address('','192.168.1','254','24'),'192.168.1.254/24')
        self.assertEqual(nc.address('192.168.1.254/24','192.168.1','254','24'),'192.168.1.254/24')
        self.assertEqual(nc.address('','','',''),'')
        with self.assertRaises(ValueError): nc.address('10.20.30.10/24','192.168.1','254','24')
        with self.assertRaises(ValueError): nc.address('','192.168.1','','')

    def test_networks_and_non24_host_boundaries(self):
        for cidr,gw in [('192.168.50.20/24','192.168.50.1'),('10.20.30.40/24','10.20.30.1'),
                        ('10.20.30.255/23','10.20.30.1'),('10.20.31.0/23','10.20.30.1')]:
            self.assertEqual(nc.validate(cidr,gw,'1.1.1.1,2606:4700:4700::1111')[0],cidr)
        for cidr,gw,dns in [('10.20.31.255/23','10.20.30.1','1.1.1.1'),
                            ('10.20.30.0/23','10.20.30.1','1.1.1.1'),
                            ('10.20.30.1/32','10.20.30.2','1.1.1.1'),
                            ('10.20.30.1/33','10.20.30.2','1.1.1.1'),
                            ('10.20.30.1/24','10.20.31.1','1.1.1.1'),
                            ('10.20.30.1/24','10.20.30.255','1.1.1.1'),
                            ('10.20.30.1/24','10.20.30.0','1.1.1.1'),
                            ('10.20.30.1/24','10.20.30.1','1.1.1.1'),
                            ('10.20.30.2/24','10.20.30.1','broken')]:
            with self.subTest(cidr=cidr,gw=gw,dns=dns),self.assertRaises(ValueError): nc.validate(cidr,gw,dns)

    def test_management_is_selected_and_ambiguous_routes_rejected(self):
        self.assertEqual(nc.management(LINKS,ADDRS,ROUTES)['interface'],'ens160')
        for routes,selected in [(ROUTES*2,''),(ROUTES,'docker0'),(ROUTES*2,'ens160')]:
            with self.assertRaises(ValueError): nc.management(LINKS,ADDRS,routes,selected)
        routes=ROUTES+[{'dst':'default','dev':'tun0','gateway':'10.0.0.1'}]
        self.assertEqual(nc.management(LINKS,ADDRS,routes,'ens160')['gateway'],'192.168.50.1')

    def test_known_conflicts_and_same_interface(self):
        nc.check_conflicts('192.168.50.100/24','ens160',ADDRS,[])
        with self.assertRaises(ValueError): nc.check_conflicts('192.168.50.100/24','ens160',ADDRS,['192.168.50.100'])
        with self.assertRaises(ValueError): nc.check_conflicts('192.168.50.100/24','enp1s0',ADDRS,[])

    def test_render_preserves_ipv6_renderer_other_nic_and_repeat(self):
        original={'network':{'version':2,'renderer':'NetworkManager','ethernets':{
            'ens160':{'dhcp4':True,'dhcp6':True,'addresses':['192.168.50.99/24','2001:db8::2/64'],
                      'routes':[{'to':'default','via':'192.168.50.1'},{'to':'default','via':'2001:db8::1'}],
                      'nameservers':{'addresses':['192.168.50.1','2001:db8::53'],'search':['example.test']}},
            'ens192':{'dhcp4':True,'dhcp6':True}}}}
        docs={'base.yaml':original}
        for cidr in ('192.168.50.20/24','192.168.50.21/24','10.20.30.255/23'):
            changed=nc.netplan_changes(docs,'ens160',LINKS[0]['address'],cidr,'192.168.50.1',['1.1.1.1'],'managed.yaml')
            base=changed['base.yaml']['network']
            self.assertEqual(base['renderer'],'NetworkManager')
            self.assertEqual(base['ethernets']['ens192'],original['network']['ethernets']['ens192'])
            selected=base['ethernets']['ens160']
            self.assertEqual(selected['addresses'],['2001:db8::2/64'])
            self.assertTrue(selected['dhcp6'])
            self.assertEqual(selected['routes'],[{'to':'default','via':'2001:db8::1'}])
            self.assertEqual(selected['nameservers']['search'],['example.test'])
            combined=dict(docs,**changed)
            self.assertEqual(nc.netplan_changes(combined,'ens160',LINKS[0]['address'],cidr,'192.168.50.1',['1.1.1.1'],'managed.yaml'),{})

    @unittest.skipUnless(shutil.which('netplan'),'Netplan parser is not installed')
    def test_real_netplan_parser_merges_only_requested_ipv4(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)/'etc/netplan'; directory.mkdir(parents=True)
            base=str(directory/'01-base.yaml'); managed=str(directory/'90-managed.yaml')
            docs={base:{'network':{'version':2,'renderer':'NetworkManager','ethernets':{
                'ens160':{'dhcp4':True,'dhcp6':True,
                    'addresses':['192.168.50.99/24','2001:db8::2/64'],
                    'routes':[{'to':'default','via':'192.168.50.1'},{'to':'default','via':'2001:db8::1'}],
                    'nameservers':{'addresses':['192.168.50.1','2001:db8::53']}},
                'ens192':{'dhcp4':False,'addresses':['192.0.2.2/24']}}}}}
            docs.update(nc.netplan_changes(docs,'ens160',LINKS[0]['address'],'10.20.30.255/23','10.20.30.1',['1.1.1.1'],managed))
            for name,doc in docs.items():
                path=Path(name);path.write_text(yaml.safe_dump(doc));path.chmod(0o600)
            # get is read-only. generate --root-dir still reloads host units in
            # the Ubuntu CLI, so it must not be used for an isolated parser test.
            result=subprocess.run([shutil.which('netplan'),'get','--root-dir',tmp],text=True,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            network=yaml.safe_load(result.stdout)['network'];nic=network['ethernets']['ens160']
            self.assertEqual(network['renderer'],'NetworkManager')
            self.assertCountEqual(nic['addresses'],['2001:db8::2/64','10.20.30.255/23'])
            self.assertTrue(nic['dhcp6']);self.assertFalse(nic['dhcp4'])
            self.assertCountEqual(nic['nameservers']['addresses'],['2001:db8::53','1.1.1.1'])
            self.assertCountEqual([r['via'] for r in nic['routes']],['2001:db8::1','10.20.30.1'])
            self.assertEqual(network['ethernets']['ens192']['addresses'],['192.0.2.2/24'])

    def test_config_roundtrip_uses_real_serializer(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg=Path(tmp)/'config.env'
            cfg.write_text('CONFIGURE_STATIC_NETWORK=true\nSTATIC_IPV4_PREFIX=10.20.30\nSTATIC_IPV4_LAST_OCTET=255\nPREFIX_LENGTH=23\nGATEWAY_IPV4=10.20.30.1\nDNS_SERVERS=1.1.1.1\nCONFIGURE_CODEX=false\n')
            result=subprocess.run(['bash','-c',r'''source "$1/scripts/00-lib.sh"
load_config; validate_config; emit_config >"$VUB_CONFIG_FILE.new"
unset STATIC_IPV4_CIDR STATIC_IPV4_PREFIX STATIC_IPV4_LAST_OCTET PREFIX_LENGTH
VUB_CONFIG_FILE+=.new
load_config; validate_config
printf '%s|%s\n' "$VUB_CONFIG_VERSION" "$STATIC_IPV4_CIDR"
''','bash',str(ROOT)],env=dict(os.environ,VUB_CONFIG_FILE=str(cfg)),text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.strip(),'5|10.20.30.255/23')
            self.assertNotIn('STATIC_IPV4_LAST_OCTET',Path(str(cfg)+'.new').read_text())


NETWORK_MOCK = r'''#!/usr/bin/python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['NETWORK_FIXTURE'])
s=json.loads((root/'mock.json').read_text())
cmd,args=pathlib.Path(sys.argv[0]).name,sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps([cmd,args])+'\n')
if cmd=='ip':
    assert args[0]=='-j',args
    if args[1:] == ['link','show']: print(json.dumps(s['links']))
    elif args[1:] == ['-4','addr','show']: print(json.dumps(s['addresses']))
    elif args[1:] == ['-4','route','show','default']: print(json.dumps(s['routes']))
    else: sys.exit(80)
elif cmd=='arping':
    if args==['-V']: print('arping from iputils 20240117' if not s.get('arp_unknown') else 'different arping')
    else:
        assert args==['-D','-I','ens160','-c','2','-w','3',s['target']],args
        print(s.get('arp_output','Sent 2 probes (2 broadcast(s))\nReceived 0 response(s)'))
        sys.exit(s.get('arp_code',0))
elif cmd=='netplan':
    if args[0]=='generate' and s.get('generate_fail'):
        s['generate_fail']=False; (root/'mock.json').write_text(json.dumps(s));sys.exit(1)
    if args[0]=='try':
        if s.get('try_fail'): sys.exit(1)
        s['addresses'][0]['addr_info'][0].update(local=s['target'],prefixlen=s.get('target_prefix',24))
        s['routes'][0]['gateway']=s.get('target_gateway','192.168.50.1')
        (root/'mock.json').write_text(json.dumps(s))
elif cmd=='systemctl': pass
elif cmd=='getent':
    if args[0]=='hosts': print('192.0.2.1 github.com')
    else: os.execv('/usr/bin/getent',['getent',*args])
else: sys.exit(81)
'''


@unittest.skipUnless(os.geteuid()==0,'isolated file ownership integration tests require root')
class NetworkPhaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.bin=self.root/'bin'; self.bin.mkdir()
        self.netplan=self.root/'netplan'; self.netplan.mkdir()
        self.managed=self.netplan/'90-vmware-ubuntu-bootstrap-static.yaml'
        self.original=self.netplan/'01-base.yaml'
        self.original.write_text('network:\n  version: 2\n  renderer: NetworkManager\n')
        self.original.chmod(0o644)
        self.config=self.root/'config.env'
        self.config.write_text('TARGET_USER=suyi\nNETWORK_INTERFACE=ens160\nCONFIGURE_STATIC_NETWORK=true\nSTATIC_IPV4_CIDR=192.168.50.20/24\nGATEWAY_IPV4=192.168.50.1\nDNS_SERVERS=1.1.1.1\nCONFIGURE_CODEX=false\n')
        for cmd in ('ip','arping','netplan','systemctl','getent'):
            path=self.bin/cmd;path.write_text(NETWORK_MOCK);path.chmod(0o755)
        self.state=dict(links=copy.deepcopy(LINKS),addresses=copy.deepcopy(ADDRS),routes=copy.deepcopy(ROUTES),target='192.168.50.20')
        self.env=dict(os.environ,PATH=str(self.bin)+':/usr/bin:/bin',NETWORK_FIXTURE=str(self.root),
            VUB_CONFIG_FILE=str(self.config),VUB_ETC_DIR=str(self.root/'etc'),VUB_STATE_DIR=str(self.root/'state'),
            VUB_LOG_DIR=str(self.root/'log'),VUB_BACKUP_ROOT=str(self.root/'backups'),VUB_BACKUP_DIR='',
            VUB_NETPLAN_DIR=str(self.netplan),VUB_NETPLAN_FILE=str(self.managed),
            VUB_NETPLAN_RUN_DIR=str(self.root/'run'),VUB_NETPLAN_LIB_DIR=str(self.root/'lib'),
            SSH_CONNECTION='192.0.2.10 12345 192.168.50.100 22',VUB_YES='true',VUB_DRY_RUN='false')

    def run_phase(self,console=False):
        (self.root/'mock.json').write_text(json.dumps(self.state))
        (self.root/'calls').write_text('')
        env=dict(self.env)
        if console: env.pop('SSH_CONNECTION',None)
        if console:
            pid,fd=pty.fork()
            if pid==0: os.execve('/bin/bash',['bash',str(ROOT/'scripts/04-static-network.sh')],env)
            output=b''
            while True:
                try: data=os.read(fd,4096)
                except OSError: break
                if not data: break
                output+=data
            os.close(fd); _,code=os.waitpid(pid,0)
            result=subprocess.CompletedProcess([],os.waitstatus_to_exitcode(code),output.decode(),'')
        else:
            result=subprocess.run(['bash',str(ROOT/'scripts/04-static-network.sh')],env=env,text=True,capture_output=True,timeout=25)
        self.calls=[json.loads(x) for x in (self.root/'calls').read_text().splitlines()]
        self.state=json.loads((self.root/'mock.json').read_text())
        return result

    def test_new_config_keeps_network_and_reports_real_address(self):
        self.config.unlink()
        result=self.run_phase()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('192.168.50.100/24',result.stdout)
        self.assertIn('02:00:00:00:00:01',result.stdout)
        self.assertNotIn('.254',result.stdout)
        self.assertFalse(self.managed.exists())
        self.assertFalse((self.root/'state/reboot-required').exists())
        self.assertFalse([x for x in self.calls if x[0] in ('netplan','arping')])

    def test_ssh_stages_and_rerun_preserves_original_backup(self):
        result=self.run_phase();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([c for c in self.calls if c[0]=='netplan'],[['netplan',['generate']]])
        saved=self.managed.read_bytes(); marker=(self.root/'state/static-network.state').read_bytes()
        backups=list((self.root/'backups').iterdir())
        self.assertIn(b'pending-reboot',marker)
        result=self.run_phase();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.managed.read_bytes(),saved)
        self.assertEqual((self.root/'state/static-network.state').read_bytes(),marker)
        self.assertEqual(list((self.root/'backups').iterdir()),backups)
        self.assertEqual(self.original.stat().st_mode & 0o777,0o644)

    def test_managed_yaml_permission_gate_is_retained(self):
        self.assertEqual(self.run_phase().returncode,0)
        command=['bash','-c','source "$1/scripts/00-lib.sh"; validate_managed_netplan_file','bash',str(ROOT)]
        result=subprocess.run(command,env=self.env,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.managed.chmod(0o666)
        self.assertNotEqual(subprocess.run(command,env=self.env,capture_output=True).returncode,0)

    def test_preserve_mode_keeps_legacy_pending_state(self):
        self.assertEqual(self.run_phase().returncode,0)
        before=(self.root/'state/static-network.state').read_bytes()
        self.config.write_text(self.config.read_text().replace('CONFIGURE_STATIC_NETWORK=true','CONFIGURE_STATIC_NETWORK=false'))
        result=self.run_phase();self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(self.managed.exists())
        self.assertEqual((self.root/'state/static-network.state').read_bytes(),before)
        self.assertIn('pending-reboot',result.stdout)
        self.assertIn('重启可能应用',result.stderr)
        self.assertFalse([x for x in self.calls if x[0] in ('netplan','arping')])

    def test_conflicts_errors_and_yes_never_apply(self):
        for state in [dict(arp_code=0,arp_output='Interface is not ARPable'),dict(arp_code=0,arp_output='Sent 0 probes (0 broadcast(s))\nReceived 0 response(s)'),dict(arp_code=1,arp_output='Received 1 response(s)'),dict(arp_code=2),dict(arp_code=1,arp_output='Permission denied'),dict(arp_unknown=True)]:
            with self.subTest(state=state):
                self.state.update(arp_code=0,arp_unknown=False)
                self.state.update(state)
                result=self.run_phase();self.assertNotEqual(result.returncode,0)
                self.assertFalse(self.managed.exists())
                self.assertFalse([x for x in self.calls if x[0]=='netplan'])
        (self.bin/'arping').unlink()
        # A wrapper makes missing-tool behavior independent of installed host packages.
        (self.bin/'arping').write_text('#!/bin/sh\nexit 127\n');(self.bin/'arping').chmod(0o755)
        self.assertNotEqual(self.run_phase().returncode,0)
        self.assertFalse(self.managed.exists())

    def test_self_address_still_checks_other_hosts(self):
        self.state['addresses'][0]['addr_info'][0]['local']=self.state['target']
        self.assertEqual(self.run_phase().returncode,0)
        self.assertTrue([x for x in self.calls if x[0]=='arping' and '-D' in x[1]])
        self.state.update(arp_code=1,arp_output='Received 1 response(s)')
        self.assertNotEqual(self.run_phase().returncode,0)
        self.assertFalse([x for x in self.calls if x[0]=='netplan'])

    def test_generate_failure_restores_files_without_ssh_switch(self):
        before=self.original.read_bytes();self.state['generate_fail']=True
        result=self.run_phase();self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertFalse(self.managed.exists(),result.stderr)
        self.assertEqual(self.original.read_bytes(),before)
        self.assertFalse((self.root/'state/static-network.state').exists())
        self.assertFalse([x for x in self.calls if x[0]=='netplan' and x[1][0] in ('apply','try')])

    def test_console_timeout_restores_and_success_marks_live(self):
        self.state['try_fail']=True
        result=self.run_phase(console=True);self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertFalse(self.managed.exists(),result.stdout)
        self.assertTrue([x for x in self.calls if x==['netplan',['apply']]])
        self.state['try_fail']=False
        result=self.run_phase(console=True);self.assertEqual(result.returncode,0,result.stdout)
        self.assertIn('status=complete',(self.root/'state/static-network.state').read_text())
        self.assertFalse((self.root/'state/reboot-required').exists())

    def test_dry_run_has_no_system_writes_arp_or_network_calls(self):
        self.env['VUB_DRY_RUN']='true'
        result=self.run_phase();self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.managed.exists())
        self.assertFalse((self.root/'state').exists())
        self.assertFalse([x for x in self.calls if x[0] in ('netplan','arping','systemctl')])

    def test_proxy_scan_bounded_and_management_cidr_independent(self):
        self.state['addresses'][0]['addr_info'][0]['prefixlen']=16
        (self.root/'mock.json').write_text(json.dumps(self.state))
        code='source "$1/scripts/00-lib.sh"; load_config; default_proxy_scan_cidr ens160; management_cidrs'
        result=subprocess.run(['bash','-c',code,'bash',str(ROOT)],env=self.env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.splitlines(),['192.168.50.0/24','192.168.0.0/16','192.168.50.0/24'])
