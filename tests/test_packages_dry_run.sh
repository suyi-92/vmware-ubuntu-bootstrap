#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "packages dry-run: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-packages-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

TARGET="${SUDO_USER:-}"
if [[ -z "$TARGET" || "$TARGET" == "root" ]]; then
  TARGET="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')"
fi
[[ -n "$TARGET" ]] || {
  echo "packages dry-run: SKIP (no regular user)"
  exit 0
}

CONFIG="$FIXTURE_ROOT/config.env"
cat >"$CONFIG" <<EOF
VUB_CONFIG_VERSION=4
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
ENABLE_UPSTREAM_APT_SOURCES=true
UPGRADE_INSTALLED_PACKAGES=true
INSTALL_DOCKER=true
CONFIGURE_FCITX5_RIME=true
ENABLE_PASSWORDLESS_SUDO=true
EOF
chmod 0600 "$CONFIG"

export VUB_CONFIG_FILE="$CONFIG"
export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_DRY_RUN=true

OUTPUT="$(bash "$ROOT/scripts/03-packages.sh" 2>&1)"
grep -Fq '安装或升级常用、运行与构建软件包' <<<"$OUTPUT"
grep -Fq 'nodejs npm node-gyp' <<<"$OUTPUT"
grep -Fq 'add-apt-repository --yes --no-update universe' <<<"$OUTPUT"
grep -Fq 'fcitx5 fcitx5-rime fcitx5-config-qt' <<<"$OUTPUT"
grep -Fq 'librime-plugin-lua librime-plugin-octagram librime-bin im-config' <<<"$OUTPUT"
grep -Fq 'verify gh, Git LFS, CMake, Node.js, npm and npx' <<<"$OUTPUT"
grep -Fq 'GitHub CLI' <<<"$OUTPUT"
grep -Fq 'systemctl daemon-reload' <<<"$OUTPUT"
grep -Fq 'systemctl start docker.socket' <<<"$OUTPUT"
grep -Fq 'systemctl restart docker.service' <<<"$OUTPUT"
grep -Fq 'verify docker.socket, docker.service and docker info' <<<"$OUTPUT"
grep -Fq 'DRY-RUN' <<<"$OUTPUT"

for path in "$VUB_ETC_DIR" "$VUB_STATE_DIR" "$VUB_LOG_DIR" "$VUB_BACKUP_ROOT"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL: packages dry-run created $path" >&2
    exit 1
  }
done

echo "packages dry-run: PASS"
