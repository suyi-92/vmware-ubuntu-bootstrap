#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "preflight dry-run: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-preflight-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

TARGET="${SUDO_USER:-}"
if [[ -z "$TARGET" || "$TARGET" == "root" ]]; then
  TARGET="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')"
fi
IFACE="$(ip -4 route show default | awk 'NR==1 {print $5}')"
IPV4="$(ip -4 -o addr show dev "$IFACE" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
CIDR="$(python3 - "$IPV4" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_network(f"{sys.argv[1]}/24", strict=False))
PY
)"

CONFIG="$FIXTURE_ROOT/config.env"
cat >"$CONFIG" <<EOF
TARGET_USER=$(printf '%q' "$TARGET")
NETWORK_INTERFACE=$(printf '%q' "$IFACE")
PROXY_PORT=7890
PROXY_SCAN_CIDR=$(printf '%q' "$CIDR")
CONFIGURE_STATIC_NETWORK=false
STATIC_IPV4_PREFIX=192.168.1
STATIC_IPV4_LAST_OCTET=254
PREFIX_LENGTH=24
ALLOW_SSH_NETWORK_CHANGE=false
HOSTNAME=""
ENABLE_UFW=false
DISABLE_SSH_PASSWORD=false
CONFIRM_SSH_KEY_LOGIN=false
CPA_BYPASS_PROXY=false
CONFIGURE_CODEX=false
RUN_CPA_SMOKE=false
RUN_CODEX_SMOKE=false
INSTALL_DOCKER=false
EOF
chmod 0600 "$CONFIG"

export VUB_CONFIG_FILE="$CONFIG"
export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_DRY_RUN=true

bash "$ROOT/scripts/01-preflight.sh" >/dev/null

for path in "$VUB_ETC_DIR" "$VUB_STATE_DIR" "$VUB_LOG_DIR" "$VUB_BACKUP_ROOT"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL: preflight dry-run created $path" >&2
    exit 1
  }
done

echo "preflight dry-run: PASS"
