#!/usr/bin/env python3
"""Check host DNS independently of HTTP proxy connectivity, without changing DNS."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys


HOSTS = ("github.com", "archive.ubuntu.com")


def probe(args, timeout=10):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return result.returncode == 0 and bool(result.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def check_dns(interface):
    resolved = bool(shutil.which("resolvectl")) and probe(
        ["systemctl", "is-active", "systemd-resolved"])
    failures = []
    for host in HOSTS:
        ok = probe(["getent", "ahostsv4", host])
        if ok and resolved:
            ok = probe(["resolvectl", "query", "--cache=no", "--type=A", host])
        if not ok:
            failures.append(host)
    if not failures:
        print("系统 DNS 验证通过：GitHub、Ubuntu 域名均可由本机解析。")
        return True
    print("系统 DNS 验证失败：" + ", ".join(failures) + "；HTTP 代理可用不能替代本机解析。",
          file=sys.stderr)
    if resolved:
        physical_ok = all(probe(["resolvectl", "query", "--cache=no", "--type=A",
                                 "--interface=" + interface, host]) for host in failures)
        if physical_ok:
            print(f"指定 {interface} 的 DNS 可以解析，请检查 VPN/TUN 的默认 DNS 路由。",
                  file=sys.stderr)
        try:
            domains = subprocess.run(["resolvectl", "domain"], capture_output=True,
                                     text=True, timeout=5)
            for line in domains.stdout.splitlines():
                if "~." in line.split():
                    print("全局 DNS 路由：" + line.strip(), file=sys.stderr)
        except (OSError, subprocess.TimeoutExpired):
            pass
    print("代理配置已单独处理；网络尚未通过全部验证。请修正所属 VPN/TUN 的 DNS 配置后重跑。",
          file=sys.stderr)
    return False


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", required=True)
    options = parser.parse_args()
    sys.exit(0 if check_dns(options.interface) else 1)
