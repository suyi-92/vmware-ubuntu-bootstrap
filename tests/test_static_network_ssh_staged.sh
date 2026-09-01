#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "static network SSH staging: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-network-staged.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

TARGET_TEST_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_TEST_USER" || "$TARGET_TEST_USER" == "root" ]]; then
  TARGET_TEST_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1; exit}')"
fi
[[ -n "$TARGET_TEST_USER" ]] || {
  echo "static network SSH staging: SKIP (no regular user)"
  exit 0
}

CONFIG_FILE="$FIXTURE_ROOT/config.env"
cat >"$CONFIG_FILE" <<EOF
TARGET_USER="$TARGET_TEST_USER"
NETWORK_INTERFACE="ens33"
CONFIGURE_STATIC_NETWORK="true"
STATIC_IPV4_PREFIX="192.168.1"
STATIC_IPV4_LAST_OCTET="254"
PREFIX_LENGTH="24"
GATEWAY_IPV4="192.168.1.1"
DNS_SERVERS="192.168.1.1"
SSH_PORT="22"
EOF

BIN_DIR="$FIXTURE_ROOT/bin"
COMMAND_LOG="$FIXTURE_ROOT/commands.log"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/ip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  "link show dev ens33") exit 0 ;;
  "-4 -o addr show dev ens33 scope global")
    echo "2: ens33    inet 192.168.1.120/24 brd 192.168.1.255 scope global ens33"
    ;;
  *) exit 0 ;;
esac
EOF
cat >"$BIN_DIR/arping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN_DIR/netplan" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$VUB_TEST_COMMAND_LOG"
EOF
chmod 0755 "$BIN_DIR/ip" "$BIN_DIR/arping" "$BIN_DIR/netplan"

export PATH="$BIN_DIR:$PATH"
export VUB_TEST_COMMAND_LOG="$COMMAND_LOG"
export VUB_CONFIG_FILE="$CONFIG_FILE"
export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_NETPLAN_FILE="$FIXTURE_ROOT/netplan/90-vmware-ubuntu-bootstrap-static.yaml"
export SSH_CONNECTION="192.0.2.10 50000 192.0.2.20 22"

bash "$ROOT/scripts/04-static-network.sh" >/dev/null
status=""
detail=""
# shellcheck disable=SC1090
source "$VUB_STATE_DIR/static-network.state"
[[ "$status" == "pending-reboot" ]]
[[ "$detail" == "ip=192.168.1.254/24;gateway=192.168.1.1;activation=reboot" ]]
[[ -f "$VUB_STATE_DIR/reboot-required" ]]
grep -Fq 'dhcp4: false' "$VUB_NETPLAN_FILE"
grep -Fq 'addresses: [192.168.1.254/24]' "$VUB_NETPLAN_FILE"
grep -Fxq 'generate' "$COMMAND_LOG"
! grep -Eq '(^| )(apply|try)( |$)' "$COMMAND_LOG"

echo "static network SSH staging: PASS"
