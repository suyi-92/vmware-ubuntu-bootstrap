from __future__ import annotations

import pathlib
import socket
import sys
import unittest
from unittest.mock import patch

SCRIPTS = pathlib.Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import proxy_scan  # noqa: E402


class ProxyScanTests(unittest.TestCase):
    def test_candidate_hosts_excludes_self(self) -> None:
        self.assertEqual(
            proxy_scan.candidate_hosts("192.168.1.0/30", "192.168.1.1"),
            ["192.168.1.2"],
        )

    def test_rejects_scan_larger_than_slash_24(self) -> None:
        with self.assertRaisesRegex(ValueError, "larger than /24"):
            proxy_scan.candidate_hosts("192.168.0.0/23", "192.168.1.10")

    def test_rejects_self_outside_cidr(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside"):
            proxy_scan.candidate_hosts("192.168.1.0/24", "192.168.2.10")

    def test_tcp_open_detects_local_listener(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            self.assertTrue(proxy_scan.tcp_open("127.0.0.1", port, timeout=0.5))

    def test_scan_retries_failed_hosts_only_and_keeps_all_candidates(self):
        calls = []
        def probe(host, port, timeout):
            calls.append(host)
            return host == "192.0.2.1" or calls.count(host) == 2
        with patch.object(proxy_scan, "tcp_open", side_effect=probe):
            self.assertEqual(proxy_scan.scan_hosts(["192.0.2.1", "192.0.2.2"], 7890, workers=1),
                             ["192.0.2.1", "192.0.2.2"])
        self.assertEqual(calls, ["192.0.2.1", "192.0.2.2", "192.0.2.2"])

    def test_scan_limits_and_closed_hosts(self):
        for options in ({"timeout": 0}, {"timeout": float("nan")}, {"timeout": 6},
                        {"workers": 0}, {"workers": 65}, {"attempts": 0}, {"attempts": 4}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                proxy_scan.scan_hosts(["192.0.2.1"], 7890, **options)
        with self.assertRaises(ValueError):
            proxy_scan.scan_hosts(["192.0.2.1"] * 257, 7890)
        with patch.object(proxy_scan, "tcp_open", return_value=False) as probe:
            self.assertEqual(proxy_scan.scan_hosts(["192.0.2.1"], 7890), [])
            self.assertEqual(probe.call_count, 2)


if __name__ == "__main__":
    unittest.main()
