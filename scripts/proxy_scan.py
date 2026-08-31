#!/usr/bin/env python3
"""Bounded TCP candidate scan for the local proxy discovery phase."""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import socket
from collections.abc import Iterable


def candidate_hosts(cidr: str, self_ip: str) -> list[str]:
    network = ipaddress.ip_network(cidr, strict=False)
    current = ipaddress.ip_address(self_ip)
    if network.version != 4 or current.version != 4:
        raise ValueError("only IPv4 is supported")
    if current not in network:
        raise ValueError("self IP is outside scan CIDR")
    if network.num_addresses > 256:
        raise ValueError("scan CIDR is larger than /24")
    return [str(ip) for ip in network.hosts() if ip != current]


def tcp_open(host: str, port: int, timeout: float = 0.30) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        return sock.connect_ex((host, port)) == 0


def scan_hosts(
    hosts: Iterable[str], port: int, timeout: float = 0.30, workers: int = 64
) -> list[str]:
    host_list = list(hosts)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        states = executor.map(lambda host: tcp_open(host, port, timeout), host_list)
    return [host for host, is_open in zip(host_list, states, strict=True) if is_open]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cidr", required=True)
    parser.add_argument("--self-ip", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--timeout", type=float, default=0.30)
    parser.add_argument("--workers", type=int, default=64)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be 1-65535")
    hosts = candidate_hosts(args.cidr, args.self_ip)
    for host in scan_hosts(hosts, args.port, args.timeout, args.workers):
        print(host)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
