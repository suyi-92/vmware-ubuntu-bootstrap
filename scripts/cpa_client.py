#!/usr/bin/env python3
"""Minimal CPA compatibility checks without putting API keys on argv."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

USER_AGENT = "vmware-ubuntu-bootstrap/1.0"


def read_key(path: str) -> str:
    key = pathlib.Path(path).read_text(encoding="utf-8").strip()
    if not key:
        raise ValueError("API key file is empty")
    if any(character.isspace() for character in key):
        raise ValueError("API key contains whitespace")
    return key


def request_json(
    url: str,
    key: str,
    *,
    payload: dict[str, object] | None = None,
    timeout: float = 30.0,
) -> dict[str, object]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method="GET" if data is None else "POST",
        headers={
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"CPA returned HTTP {exc.code} for {url}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"CPA request failed for {url}: {exc.reason}") from exc
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"CPA returned non-JSON data for {url}") from exc
    if not isinstance(decoded, dict):
        raise RuntimeError(f"CPA returned a non-object JSON value for {url}")
    if decoded.get("error") is not None:
        raise RuntimeError(f"CPA returned an API error for {url}")
    return decoded


def model_ids(payload: dict[str, object]) -> list[str]:
    data = payload.get("data")
    if not isinstance(data, list):
        raise RuntimeError("/models response does not contain a data array")
    result: list[str] = []
    for item in data:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            result.append(item["id"])
    return result


def check_models(base_url: str, key: str, model: str, list_models: bool) -> None:
    ids = model_ids(request_json(f"{base_url.rstrip('/')}/models", key))
    if model and model not in ids:
        raise RuntimeError(f"configured model is not present in /models: {model}")
    if list_models:
        for item in ids:
            print(item)


def check_responses(base_url: str, key: str, model: str) -> None:
    payload = request_json(
        f"{base_url.rstrip('/')}/responses",
        key,
        payload={
            "model": model,
            "input": "Reply exactly OK.",
            "max_output_tokens": 16,
            "stream": False,
        },
        timeout=90.0,
    )
    if not isinstance(payload.get("id"), str) or not (
        isinstance(payload.get("output"), list) or payload.get("object") == "response"
    ):
        raise RuntimeError("/responses returned JSON but not a compatible Responses object")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("models", "responses"))
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--list", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    key = read_key(args.key_file)
    if args.command == "models":
        check_models(args.base_url, key, args.model, args.list)
    else:
        if not args.model:
            raise ValueError("--model is required for responses")
        check_responses(args.base_url, key, args.model)
    print("OK", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
