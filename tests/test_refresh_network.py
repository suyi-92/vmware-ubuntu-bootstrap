"""Run the Linux entrypoint against mock network commands, never the host network."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
UUID = "11111111-2222-3333-4444-555555555555"


@unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0, "Linux root fixture required")
class RefreshNetworkTests(unittest.TestCase):
    def setUp(self):
        import pwd

        users = [p.pw_name for p in pwd.getpwall() if 1000 <= p.pw_uid < 65534]
        if not users:
            self.skipTest("fixture needs an existing ordinary user")
        self.tmp = tempfile.TemporaryDirectory(prefix="vub-refresh-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base / "scripts").mkdir()
        (self.base / "bin").mkdir()
        for name in ("00-lib.sh", "network-lib.sh", "network_config.py", "docker-local.sh", "network_health.py"):
            shutil.copy2(ROOT / "scripts" / name, self.base / "scripts" / name)
        shutil.copy2(ROOT / "refresh-network.sh", self.base / "refresh-network.sh")
        self.config = self.base / "config.env"
        self.config.write_text(
            f"TARGET_USER={users[0]}\nNETWORK_INTERFACE=ens33\n"
            "PROXY_HOST=192.168.1.100\nPROXY_SCAN_CIDR=192.168.1.0/24\n"
            "PROXY_PORT=7890\nSSH_PORT=2222\nCONFIGURE_STATIC_NETWORK=false\n",
            encoding="utf-8",
        )
        self.original_config = self.config.read_bytes()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("VUB_", "SSH_"))}
        self.env.update(
            PATH=f"{self.base / 'bin'}:/usr/bin:/bin",
            FIXTURE=str(self.base),
            VUB_ETC_DIR=str(self.base / "etc"),
            VUB_STATE_DIR=str(self.base / "state"),
            VUB_LOG_DIR=str(self.base / "log"),
            VUB_BACKUP_ROOT=str(self.base / "backup"),
            VUB_NETPLAN_FILE=str(self.base / "static.yaml"),
            FIXTURE_UUID=UUID,
        )
        self.write_executable("bootstrap.sh", """#!/bin/bash
printf 'proxy %s interface=%s host=%s port=%s dry=%s yes=%s\n' "$*" \
  "$VUB_REFRESH_INTERFACE" "$VUB_FORCE_PROXY_HOST" "$VUB_REFRESH_PROXY_PORT" \
  "$VUB_DRY_RUN" "$VUB_YES" >>"$FIXTURE/events"
exit "${FAIL_PROXY:-0}"
""")
        self.write_executable("bin/ip", """#!/usr/bin/python3
import json, os, sys
from pathlib import Path
ready = not os.getenv('NO_ROUTE') or (Path(os.environ['FIXTURE']) / 'renewed').exists()
if 'link' in sys.argv:
    result = [{'ifname': 'ens33', 'link_type': 'ether', 'address': '00:11:22:33:44:55'}]
elif 'addr' in sys.argv:
    result = [{'ifname': 'ens33', 'addr_info': [
        {'family': 'inet', 'scope': 'global', 'local': '192.168.2.20', 'prefixlen': 24}]}] if ready else []
else:
    result = [{'dev': 'ens33', 'gateway': '192.168.2.1'}] if ready else []
print(json.dumps(result))
""")
        self.write_executable("bin/nmcli", """#!/usr/bin/python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
base = Path(os.environ['FIXTURE'])
if args[0] == '-g':
    values = {
        'GENERAL.TYPE': 'ethernet',
        'GENERAL.CON-UUID': '--' if os.getenv('DISCONNECTED') else os.environ['FIXTURE_UUID'],
        'ipv4.method': os.getenv('METHOD', 'auto'),
        'connection.type': os.getenv('PROFILE_TYPE', '802-3-ethernet'),
        'connection.interface-name': os.getenv('PROFILE_INTERFACE', 'ens33'),
        '802-3-ethernet.mac-address': os.getenv('PROFILE_MAC', ''),
    }
    print(values[args[1]])
else:
    with (base / 'events').open('a') as f:
        f.write('nmcli ' + ' '.join(args) + '\\n')
    if 'disconnect' in args and os.getenv('FAIL_DISCONNECT'):
        sys.exit(3)
    if 'up' in args:
        if os.getenv('FAIL_DHCP'):
            sys.exit(10)
        (base / 'renewed').touch()
""")
        self.write_executable("bin/ufw", """#!/bin/bash
if [[ "$1" == status ]]; then
  echo "Status: ${UFW_STATUS:-inactive}"
else
  printf 'ufw %s\n' "$*" >>"$FIXTURE/events"
fi
""")
        self.write_executable("bin/getent", """#!/bin/bash
if [[ "$1" == ahostsv4 ]]; then
  printf 'dns %s\\n' "$2" >>"$FIXTURE/events"
  [[ "${FAIL_DNS:-0}" == 0 ]] || exit 2
  echo '192.0.2.1 STREAM fixture.example'
else
  exec /usr/bin/getent "$@"
fi
""")
        self.write_executable("bin/systemctl", "#!/bin/bash\nexit 3\n")

    def write_executable(self, name, content):
        path = self.base / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def run_refresh(self, *args, **environment):
        return subprocess.run(
            ["bash", str(self.base / "refresh-network.sh"), *args],
            cwd=self.base, env={**self.env, **environment},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
        )

    def events(self):
        path = self.base / "events"
        return path.read_text() if path.exists() else ""

    def test_default_refresh_keeps_link_and_original_config(self):
        result = self.run_refresh()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("nmcli", self.events())
        self.assertIn("--phase proxy-refresh", self.events())
        self.assertIn("interface=ens33 host= port=7890", self.events())
        self.assertIn("yes=true", self.events())
        self.assertIn("source /etc/profile.d/", result.stdout)
        self.assertEqual(self.original_config, self.config.read_bytes())

    def test_explicit_host_port_and_config_path_with_spaces(self):
        alternate = self.base / "saved config.env"
        self.config.rename(alternate)
        result = self.run_refresh("--config", str(alternate), "--proxy-host", "192.168.2.99", "--proxy-port", "7897")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("host=192.168.2.99 port=7897", self.events())

    def test_renew_finishes_before_proxy(self):
        result = self.run_refresh("--renew")
        self.assertEqual(result.returncode, 0, result.stdout)
        events = self.events()
        self.assertLess(events.index("device disconnect ens33"), events.index("connection up uuid"))
        self.assertLess(events.index("connection up uuid"), events.index("proxy "))

    def test_disconnected_profile_recovers_without_old_address_or_route(self):
        result = self.run_refresh("--renew", "--interface", "ens33", "--connection", UUID,
                                  DISCONNECTED="1", NO_ROUTE="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("disconnect", self.events())
        self.assertIn(f"connection up uuid {UUID} ifname ens33", self.events())
        self.assertIn("proxy ", self.events())

    def test_disconnect_timeout_still_attempts_reactivation(self):
        result = self.run_refresh("--renew", FAIL_DISCONNECT="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("connection up uuid", self.events())
        self.assertIn("proxy ", self.events())

    def test_unfinished_backup_stops_before_network_changes(self):
        (self.base / "state").mkdir()
        (self.base / "state" / "active-backup").write_text("/pending/backup\n")
        result = self.run_refresh("--renew")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), "")

    def test_dhcp_failure_never_runs_proxy(self):
        result = self.run_refresh("--renew", FAIL_DHCP="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DHCP 重连失败", result.stdout)
        self.assertNotIn("proxy ", self.events())

    def test_ssh_static_and_wrong_profiles_never_disconnect(self):
        for flags in ({"SSH_CONNECTION": "a b c d"}, {"METHOD": "manual"},
                      {"PROFILE_TYPE": "bridge"}, {"PROFILE_INTERFACE": "ens34"},
                      {"PROFILE_MAC": "00:00:00:00:00:00"}):
            with self.subTest(flags=flags):
                result = self.run_refresh("--renew", **flags)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.events(), "")

    def test_pending_static_config_never_disconnects(self):
        (self.base / "static.yaml").write_text("network: {}\n")
        result = self.run_refresh("--renew")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), "")

    def test_renew_dry_run_does_not_scan_or_mutate(self):
        result = self.run_refresh("--renew", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.events(), "")
        self.assertFalse((self.base / "state").exists())

    def test_dry_run_only_plans_new_ufw_lan(self):
        result = self.run_refresh("--dry-run", UFW_STATUS="active")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("192.168.2.0/24", result.stdout)
        self.assertIn("2222", result.stdout)
        self.assertNotIn("ufw ", self.events())
        self.assertFalse((self.base / "backup").exists())

    def test_invalid_args_and_no_route_do_not_refresh(self):
        for args in (("--proxy-port",), ("--proxy-port", "invalid"),
                     ("--proxy-host", "1.2.3.4;id"), ("--connection", UUID)):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_refresh(*args).returncode, 0)
                self.assertEqual(self.events(), "")
        self.assertNotEqual(self.run_refresh(NO_ROUTE="1").returncode, 0)
        self.assertEqual(self.events(), "")

    def test_proxy_failure_stops_before_ufw(self):
        result = self.run_refresh(FAIL_PROXY="7", UFW_STATUS="active")
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("ufw ", self.events())
        self.assertNotIn("刷新完成", result.stdout)

    def test_dns_failure_after_proxy_never_claims_full_recovery(self):
        result = self.run_refresh(FAIL_DNS="1", UFW_STATUS="active")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("proxy ", self.events())
        self.assertIn("系统 DNS 验证失败", result.stdout)
        self.assertNotIn("刷新完成", result.stdout)
        self.assertNotIn("ufw ", self.events())

    def test_dry_run_does_not_run_final_dns_acceptance(self):
        result = self.run_refresh("--dry-run", FAIL_DNS="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("dns ", self.events())


if __name__ == "__main__":
    unittest.main()
