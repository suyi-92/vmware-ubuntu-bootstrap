#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "sudo policy dry-run: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-sudo-policy-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

TARGET="${SUDO_USER:-}"
if [[ -z "$TARGET" || "$TARGET" == "root" ]]; then
  TARGET="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')"
fi
[[ -n "$TARGET" ]] || {
  echo "sudo policy dry-run: SKIP (no regular user)"
  exit 0
}

CONFIG="$FIXTURE_ROOT/config.env"
cat >"$CONFIG" <<EOF
VUB_CONFIG_VERSION=3
TARGET_USER=$(printf '%q' "$TARGET")
NETWORK_INTERFACE=""
PROXY_PORT=7890
CONFIGURE_STATIC_NETWORK=false
STATIC_IPV4_PREFIX=192.168.1
STATIC_IPV4_LAST_OCTET=254
PREFIX_LENGTH=24
HOSTNAME=""
TIMEZONE=America/New_York
ENABLE_UFW=false
DISABLE_SSH_PASSWORD=false
CONFIRM_SSH_KEY_LOGIN=false
CPA_BYPASS_PROXY=false
CONFIGURE_CODEX=false
RUN_CPA_SMOKE=false
RUN_CODEX_SMOKE=false
ENABLE_UPSTREAM_APT_SOURCES=false
UPGRADE_INSTALLED_PACKAGES=false
INSTALL_DOCKER=false
ENABLE_PASSWORDLESS_SUDO=true
EOF
chmod 0600 "$CONFIG"

export VUB_CONFIG_FILE="$CONFIG"
export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_PASSWORDLESS_SUDOERS_FILE="$FIXTURE_ROOT/sudoers/passwordless"
export VUB_DRY_RUN=true

OUTPUT="$(bash "$ROOT/scripts/03-sudo-policy.sh" 2>&1)"
grep -Fq 'DRY-RUN' <<<"$OUTPUT"
grep -Fq "已为 $TARGET 开启免密 sudo" <<<"$OUTPUT"
[[ ! -e "$VUB_PASSWORDLESS_SUDOERS_FILE" ]] || {
  echo "FAIL: sudo policy dry-run wrote sudoers file" >&2
  exit 1
}

for path in "$VUB_ETC_DIR" "$VUB_STATE_DIR" "$VUB_LOG_DIR" "$VUB_BACKUP_ROOT"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL: sudo policy dry-run created $path" >&2
    exit 1
  }
done

echo "sudo policy dry-run: PASS"
