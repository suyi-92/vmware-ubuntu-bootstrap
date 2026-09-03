#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "input method dry-run: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-input-method-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

TARGET="${SUDO_USER:-}"
if [[ -z "$TARGET" || "$TARGET" == "root" ]]; then
  TARGET="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')"
fi
[[ -n "$TARGET" ]] || {
  echo "input method dry-run: SKIP (no regular user)"
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
ENABLE_UPSTREAM_APT_SOURCES=false
UPGRADE_INSTALLED_PACKAGES=false
INSTALL_DOCKER=false
CONFIGURE_FCITX5_RIME=true
ENABLE_PASSWORDLESS_SUDO=true
EOF
chmod 0600 "$CONFIG"

export VUB_CONFIG_FILE="$CONFIG"
export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_RIME_DIR="$FIXTURE_ROOT/home/.local/share/fcitx5/rime"
export VUB_PLUM_DIR="$FIXTURE_ROOT/home/plum"
export VUB_FCITX5_CONFIG_DIR="$FIXTURE_ROOT/home/.config/fcitx5"
export VUB_XINPUTRC="$FIXTURE_ROOT/home/.xinputrc"
export VUB_DRY_RUN=true
export VUB_TESTING=true

OUTPUT="$(bash "$ROOT/scripts/04-input-method.sh" 2>&1)"
grep -Fq 'stop the running Fcitx5 user daemon' <<<"$OUTPUT"
grep -Fq 'im-config -n fcitx5' <<<"$OUTPUT"
grep -Fq 'https://github.com/rime/plum.git' <<<"$OUTPUT"
grep -Fq 'rime_frontend=fcitx5-rime' <<<"$OUTPUT"
grep -Fq 'iDvel/rime-ice' <<<"$OUTPUT"
grep -Fq 'rime_deployer --build' <<<"$OUTPUT"
grep -Fq 'phase input-method -> complete' <<<"$OUTPUT"
grep -Fq 'default_im=rime;active_by_default=true;schema=rime_ice;page_size=9' \
  "$ROOT/scripts/04-input-method.sh"
grep -Fxq 'DefaultIM=rime' "$ROOT/templates/fcitx5-profile.conf.tpl"
grep -Fq '"menu/page_size": 9' "$ROOT/templates/rime-default.custom.yaml.tpl"
grep -Fq 'accept: minus, send: Page_Up' "$ROOT/templates/rime-default.custom.yaml.tpl"
grep -Fq 'accept: equal, send: Page_Down' "$ROOT/templates/rime-default.custom.yaml.tpl"
if grep -Fq 'rime_ice_suggestion' "$ROOT/templates/rime-default.custom.yaml.tpl"; then
  echo "FAIL: unsupported rime_ice_suggestion include was rendered" >&2
  exit 1
fi

for path in "$VUB_ETC_DIR" "$VUB_STATE_DIR" "$VUB_LOG_DIR" "$VUB_BACKUP_ROOT" \
  "$FIXTURE_ROOT/home"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL: input method dry-run created $path" >&2
    exit 1
  }
done

echo "input method dry-run: PASS"
