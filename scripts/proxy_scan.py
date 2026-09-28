#!/usr/bin/env python3
"""Bounded TCP candidate scan for the local proxy discovery phase."""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import math
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


def tcp_open(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            return sock.connect_ex((host, port)) == 0
    except OSError:
        return False


def scan_hosts(
    hosts: Iterable[str], port: int, timeout: float = 1.0, workers: int = 32,
    attempts: int = 2,
) -> list[str]:
    if not math.isfinite(timeout) or not 0.1 <= timeout <= 5:
        raise ValueError("timeout must be 0.1-5 seconds")
    if not 1 <= workers <= 64 or not 1 <= attempts <= 3:
        raise ValueError("workers must be 1-64 and attempts must be 1-3")
    host_list = list(hosts)
    if len(host_list) > 256:
        raise ValueError("at most 256 hosts may be scanned")
    found = set()
    pending = host_list
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        for _ in range(attempts):
            states = executor.map(lambda host: tcp_open(host, port, timeout), pending)
            found.update(host for host, is_open in zip(pending, states, strict=True) if is_open)
            pending = [host for host in pending if host not in found]
            if not pending:
                break
    return [host for host in host_list if host in found]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cidr", required=True)
    parser.add_argument("--self-ip", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("--attempts", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be 1-65535")
    try:
        hosts = candidate_hosts(args.cidr, args.self_ip)
        found = scan_hosts(hosts, args.port, args.timeout, args.workers, args.attempts)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    for host in found:
        print(host)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
