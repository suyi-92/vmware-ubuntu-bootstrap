#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "gitconfig permissions: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-gitconfig-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT
chmod 0755 "$FIXTURE_ROOT"

TARGET="${SUDO_USER:-}"
if [[ -z "$TARGET" || "$TARGET" == "root" ]]; then
  TARGET="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')"
fi
[[ -n "$TARGET" ]] || {
  echo "gitconfig permissions: SKIP (no regular user)"
  exit 0
}

SYSTEM_CONFIG="$FIXTURE_ROOT/gitconfig"
USER_HOME="$FIXTURE_ROOT/home"
TARGET_GROUP="$(id -gn "$TARGET")"
install -d -m 0755 -o "$TARGET" -g "$TARGET_GROUP" "$USER_HOME"

# shellcheck source=../scripts/00-lib.sh
source "$ROOT/scripts/00-lib.sh"

ORIGINAL_UMASK="$(umask)"
SECRET_FILE="$(make_private_temp_file "$FIXTURE_ROOT/secret.XXXXXX")"
[[ "$(umask)" == "$ORIGINAL_UMASK" ]]
[[ "$(stat -c '%a' "$SECRET_FILE")" == "600" ]]

(
  umask 077
  git config --file "$SYSTEM_CONFIG" --add include.path /tmp/vub-fixture
)
[[ "$(stat -c '%a' "$SYSTEM_CONFIG")" == "600" ]]

normalize_system_config_permissions "$SYSTEM_CONFIG"
[[ "$(stat -c '%U:%G:%a' "$SYSTEM_CONFIG")" == "root:root:644" ]]
runuser -u "$TARGET" -- test -r "$SYSTEM_CONFIG"
runuser -u "$TARGET" -- env HOME="$USER_HOME" GIT_CONFIG_SYSTEM="$SYSTEM_CONFIG" \
  git config --global --add include.path /tmp/vub-fixture

echo "gitconfig permissions: PASS"
