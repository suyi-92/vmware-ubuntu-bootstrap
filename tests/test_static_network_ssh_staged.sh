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
NETPLAN_DIR="$FIXTURE_ROOT/netplan"
ORIGINAL_NETPLAN="$NETPLAN_DIR/01-network-manager-all.yaml"
mkdir -p "$BIN_DIR" "$NETPLAN_DIR"
printf 'network:\n  version: 2\n' >"$ORIGINAL_NETPLAN"
chmod 0644 "$ORIGINAL_NETPLAN"
cat >"$BIN_DIR/ip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  "-j link show") echo '[{"ifname":"ens33","link_type":"ether","address":"02:00:00:00:00:01"}]' ;;
  "-j -4 addr show") echo '[{"ifname":"ens33","addr_info":[{"family":"inet","local":"192.168.1.120","prefixlen":24,"scope":"global"}]}]' ;;
  "-j -4 route show default") echo '[{"dev":"ens33","gateway":"192.168.1.1"}]' ;;
  *) exit 1 ;;
esac
EOF
cat >"$BIN_DIR/arping" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == -V ]]; then echo 'arping from iputils'; else printf 'Sent 2 probes (2 broadcast(s))\nReceived 0 response(s)\n'; fi
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
export VUB_NETPLAN_DIR="$NETPLAN_DIR"
export VUB_NETPLAN_RUN_DIR="$FIXTURE_ROOT/run"
export VUB_NETPLAN_LIB_DIR="$FIXTURE_ROOT/lib"
export VUB_NETPLAN_FILE="$NETPLAN_DIR/90-vmware-ubuntu-bootstrap-static.yaml"
export SSH_CONNECTION="192.0.2.10 50000 192.0.2.20 22"

bash "$ROOT/scripts/04-static-network.sh" >/dev/null
status=""
detail=""
# shellcheck disable=SC1090
source "$VUB_STATE_DIR/static-network.state"
[[ "$status" == "pending-reboot" ]]
[[ "$detail" == "ip=192.168.1.254/24;gateway=192.168.1.1;activation=reboot" ]]
[[ -f "$VUB_STATE_DIR/reboot-required" ]]
[[ "$(stat -c '%U:%G:%a' "$ORIGINAL_NETPLAN")" == "root:root:644" ]]
grep -Fq 'dhcp4: false' "$VUB_NETPLAN_FILE"
grep -Fq -- '- 192.168.1.254/24' "$VUB_NETPLAN_FILE"
grep -Fxq 'generate' "$COMMAND_LOG"
! grep -Eq '(^| )(apply|try)( |$)' "$COMMAND_LOG"

echo "static network SSH staging: PASS"
