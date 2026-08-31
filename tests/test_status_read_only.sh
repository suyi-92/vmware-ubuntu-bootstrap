#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "status read-only: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-status-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_CONFIG_FILE="$FIXTURE_ROOT/missing-config.env"

bash "$ROOT/scripts/02-proxy.sh" status >/dev/null
bash "$ROOT/scripts/09-status.sh" >/dev/null

for path in "$VUB_ETC_DIR" "$VUB_STATE_DIR" "$VUB_LOG_DIR" "$VUB_BACKUP_ROOT"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL: status created $path" >&2
    exit 1
  }
done

echo "status read-only: PASS"
