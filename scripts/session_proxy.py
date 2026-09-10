#!/usr/bin/env python3
"""Synchronize only proxy variables in the existing user's activation environment."""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys


KEYS = tuple(name for lower in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")
             for name in (lower, lower.upper()))


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode})")
    return result.stdout


def snapshot():
    values = {}
    for line in command(["systemctl", "--user", "show-environment"]).splitlines():
        if line.partition("=")[0] not in KEYS:
            continue
        # systemctl emits shell-escaped assignments. Never execute them as shell code.
        parts = shlex.split(line)
        if len(parts) == 1:
            key, separator, value = parts[0].partition("=")
            if separator and key in KEYS:
                values[key] = value
    return values


def restore(values):
    if (not isinstance(values, dict) or set(values) - set(KEYS)
            or any(not isinstance(v, str) or "\0" in v for v in values.values())):
        raise ValueError("invalid proxy environment snapshot")
    # D-Bus has no unset API: an empty proxy value disables it. Restore actual
    # absence separately in the systemd user manager, which does support unset.
    command(["dbus-update-activation-environment", "--systemd",
             *(key + "=" + values.get(key, "") for key in KEYS)])
    absent = [key for key in KEYS if key not in values]
    if absent:
        command(["systemctl", "--user", "unset-environment", *absent])
    if snapshot() != values:
        raise RuntimeError("user manager proxy verification failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("snapshot", "restore"))
    args = parser.parse_args()
    if args.action == "snapshot":
        print(json.dumps(snapshot(), sort_keys=True))
    else:
        restore(json.load(sys.stdin))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"用户会话代理同步失败：{error}", file=sys.stderr)
        sys.exit(1)
