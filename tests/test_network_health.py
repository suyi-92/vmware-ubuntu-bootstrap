import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("network_health", Path(__file__).resolve().parents[1] / "scripts/network_health.py")
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class NetworkHealthTests(unittest.TestCase):
    def test_working_dns_includes_uncached_resolved_queries(self):
        with patch.object(health.shutil, "which", return_value="/usr/bin/resolvectl"), \
                patch.object(health, "probe", return_value=True) as probe, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(health.check_dns("ens33"))
        for host in health.HOSTS:
            self.assertIn((["resolvectl", "query", "--cache=no", "--type=A", host],),
                          [c.args for c in probe.call_args_list])

    def test_broken_global_dns_identifies_tun_without_changing_it(self):
        def probe(args):
            return args[0] == "systemctl" or "--interface=ens33" in args
        result = subprocess.CompletedProcess([], 0, "Link 9 (tun0): ~.\nLink 2 (ens33):\n", "")
        with patch.object(health.shutil, "which", return_value="/usr/bin/resolvectl"), \
                patch.object(health, "probe", side_effect=probe), \
                patch.object(health.subprocess, "run", return_value=result) as run, \
                contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertFalse(health.check_dns("ens33"))
        self.assertIn("指定 ens33 的 DNS 可以解析", output.getvalue())
        self.assertIn("tun0", output.getvalue())
        run.assert_called_once_with(["resolvectl", "domain"], capture_output=True, text=True, timeout=5)

    def test_systems_without_resolved_can_pass_using_nss(self):
        with patch.object(health.shutil, "which", return_value=None), \
                patch.object(health, "probe", return_value=True) as probe, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(health.check_dns("ens33"))
        self.assertTrue(all(c.args[0][0] == "getent" for c in probe.call_args_list))

    def test_cached_nss_success_cannot_hide_broken_resolved(self):
        with patch.object(health.shutil, "which", return_value="/usr/bin/resolvectl"), \
                patch.object(health, "probe", side_effect=lambda args: args[0] != "resolvectl"), \
                patch.object(health.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(health.check_dns("ens33"))

    def test_timeout_is_bounded_and_fails(self):
        with patch.object(health.subprocess, "run", side_effect=subprocess.TimeoutExpired("getent", 10)):
            self.assertFalse(health.probe(["getent", "ahostsv4", "github.com"]))
