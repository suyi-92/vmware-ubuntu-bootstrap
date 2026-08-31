#!/usr/bin/env python3
"""Render a minimal Codex CPA profile with safely escaped TOML strings."""

from __future__ import annotations

import argparse
import json


def toml_string(value: str) -> str:
    # TOML basic strings and JSON strings share the escapes used here.
    return json.dumps(value, ensure_ascii=False)


def render(model: str, base_url: str, token_helper: str) -> str:
    return f"""# Managed by vmware-ubuntu-bootstrap.
model = {toml_string(model)}
model_provider = "cpa"

[model_providers.cpa]
name = "CPA"
base_url = {toml_string(base_url)}
wire_api = "responses"

[model_providers.cpa.auth]
command = {toml_string(token_helper)}
timeout_ms = 1000
refresh_interval_ms = 0
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--token-helper", required=True)
    args = parser.parse_args()
    print(render(args.model, args.base_url, args.token_helper), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
