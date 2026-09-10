import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("session_proxy", Path(__file__).resolve().parents[1] / "scripts/session_proxy.py")
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


class SessionProxyTests(unittest.TestCase):
    def test_snapshot_reads_only_proxy_variables_without_executing_values(self):
        value = "HTTPS_PROXY='http://proxy.example:7890'\nno_proxy='a b'\nPRIVATE_KEY=ignored\nBAD='\n"
        with patch.object(session, "command", return_value=value) as command:
            self.assertEqual(session.snapshot(), {"HTTPS_PROXY": "http://proxy.example:7890", "no_proxy": "a b"})
        command.assert_called_once_with(["systemctl", "--user", "show-environment"])

    def test_restore_preserves_absence_and_limits_changes_to_proxy_keys(self):
        values = {"HTTPS_PROXY": "http://proxy.example:7890"}
        with patch.object(session, "command", return_value="") as command, \
                patch.object(session, "snapshot", return_value=values):
            session.restore(values)
        calls = [c.args[0] for c in command.call_args_list]
        self.assertEqual(calls[0][:2], ["dbus-update-activation-environment", "--systemd"])
        self.assertIn("HTTPS_PROXY=http://proxy.example:7890", calls[0])
        self.assertIn("http_proxy=", calls[0])
        self.assertEqual(set(calls[1][3:]), set(session.KEYS) - {"HTTPS_PROXY"})

    def test_invalid_snapshot_does_not_change_environment(self):
        for values in ({"LD_PRELOAD": "/tmp/library"}, {"http_proxy": None},
                       {"HTTP_PROXY": "bad\0value"}, []):
            with self.subTest(values=values), patch.object(session, "command") as command:
                with self.assertRaises(ValueError):
                    session.restore(values)
                command.assert_not_called()

    def test_verification_failure_is_not_reported_as_success(self):
        with patch.object(session, "command", return_value=""), \
                patch.object(session, "snapshot", return_value={"HTTP_PROXY": "old"}):
            with self.assertRaises(RuntimeError):
                session.restore({"HTTP_PROXY": "new"})

    def test_failed_dbus_command_does_not_expose_proxy_credentials(self):
        result = subprocess.CompletedProcess([], 1, "", "private credentials")
        with patch.object(session.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "dbus-update-activation-environment failed") as error:
                session.restore({"http_proxy": "http://secret@proxy.example"})
        self.assertNotIn("secret", str(error.exception))
