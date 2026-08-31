from __future__ import annotations

import pathlib
import socket
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
