#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo "remote install entry: SKIP (must run as a regular user)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d "$HOME/.vub-remote-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

OUTPUT="$(
  VUB_REPOSITORY_URL="file://$ROOT" \
  VUB_INSTALL_DIR="$FIXTURE_ROOT/vmware-ubuntu-bootstrap" \
    bash <(cat "$ROOT/install.sh") --help
)"

[[ -d "$FIXTURE_ROOT/vmware-ubuntu-bootstrap/.git" ]]
grep -Fq 'VMware Ubuntu Bootstrap' <<<"$OUTPUT"
grep -Fq '用法：' <<<"$OUTPUT"

echo "remote install entry: PASS"
