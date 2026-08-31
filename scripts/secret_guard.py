#!/usr/bin/env python3
"""Check that an exact secret does not appear outside its credential file."""

from __future__ import annotations

import argparse
import pathlib


def scan(secret_file: pathlib.Path, roots: list[pathlib.Path]) -> list[pathlib.Path]:
    secret = secret_file.read_bytes().strip()
    if not secret:
        raise ValueError("secret file is empty")
    hits: list[pathlib.Path] = []
    for root in roots:
        if not root.exists():
            continue
        paths = [root] if root.is_file() else root.rglob("*")
        for path in paths:
            if not path.is_file() or path.absolute() == secret_file.absolute():
                continue
            try:
                if secret in path.read_bytes():
                    hits.append(path)
            except (OSError, PermissionError):
                continue
    return hits


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--secret-file", required=True, type=pathlib.Path)
    parser.add_argument("roots", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    hits = scan(args.secret_file, args.roots)
    for path in hits:
        print(path)
    return 1 if hits else 0


if __name__ == "__main__":
    raise SystemExit(main())
