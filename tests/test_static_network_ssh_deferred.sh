#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "static network SSH deferral: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-network-deferred.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

TARGET_TEST_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_TEST_USER" || "$TARGET_TEST_USER" == "root" ]]; then
  TARGET_TEST_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1; exit}')"
fi
[[ -n "$TARGET_TEST_USER" ]] || {
  echo "static network SSH deferral: SKIP (no regular user)"
  exit 0
}

CONFIG_FILE="$FIXTURE_ROOT/config.env"
cat >"$CONFIG_FILE" <<EOF
TARGET_USER="$TARGET_TEST_USER"
CONFIGURE_STATIC_NETWORK="true"
ALLOW_SSH_NETWORK_CHANGE="false"
EOF

export VUB_CONFIG_FILE="$CONFIG_FILE"
export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export SSH_CONNECTION="192.0.2.10 50000 192.0.2.20 22"

bash "$ROOT/scripts/04-static-network.sh" >/dev/null
# shellcheck disable=SC1090
source "$VUB_STATE_DIR/static-network.state"
[[ "$status" == "deferred" ]]
[[ "$detail" == "requires VMware console" ]]

echo "static network SSH deferral: PASS"
