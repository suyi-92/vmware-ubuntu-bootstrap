#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "static-network"
require_root
load_config true
resolve_real_user

if ! is_true "$CONFIGURE_STATIC_NETWORK"; then
  mark_phase skipped "disabled by config"
  info "按配置跳过固定网络。"
  exit 0
fi

require_command ip
require_command python3
require_command netplan

[[ -n "$NETWORK_INTERFACE" ]] || NETWORK_INTERFACE="$(current_interface)"
ip link show dev "$NETWORK_INTERFACE" >/dev/null 2>&1 || die "网卡不存在：$NETWORK_INTERFACE"

if [[ -n "${SSH_CONNECTION:-}" ]] && ! is_true "$ALLOW_SSH_NETWORK_CHANGE"; then
  die "当前仅通过 SSH 操作；为防断联，必须在 VMware 控制台执行或设置 ALLOW_SSH_NETWORK_CHANGE=true。"
fi

TARGET_IPV4="${STATIC_IPV4_PREFIX}.${STATIC_IPV4_LAST_OCTET}"
NORMALIZED="$(python3 - "$TARGET_IPV4" "$PREFIX_LENGTH" "$GATEWAY_IPV4" "$DNS_SERVERS" <<'PY'
import ipaddress
import re
import sys

address, prefix, gateway, raw_dns = sys.argv[1:]
interface = ipaddress.ip_interface(f"{address}/{prefix}")
gw = ipaddress.ip_address(gateway)
if interface.version != 4 or gw.version != 4:
    raise SystemExit("只支持 IPv4")
if address == str(interface.network.network_address) or address == str(interface.network.broadcast_address):
    raise SystemExit("不能使用网络地址或广播地址")
if gw not in interface.network or gw == interface.ip:
    raise SystemExit("网关必须与目标地址同网段且不能相同")
dns_values = [x for x in re.split(r"[\s,]+", raw_dns.strip()) if x]
if not dns_values:
    raise SystemExit("至少配置一个 DNS")
for value in dns_values:
    ipaddress.ip_address(value)
print(str(interface.ip))
print(str(gw))
print(" ".join(dns_values))
PY
)" || die "固定网络参数校验失败。"

mapfile -t NORMALIZED_LINES <<<"$NORMALIZED"
TARGET_IPV4="${NORMALIZED_LINES[0]}"
GATEWAY_IPV4="${NORMALIZED_LINES[1]}"
DNS_SERVERS="${NORMALIZED_LINES[2]}"

if [[ -r "$VUB_ETC_DIR/proxy.env" ]]; then
  # shellcheck disable=SC1090
  source "$VUB_ETC_DIR/proxy.env"
  [[ "${VUB_PROXY_HOST:-}" != "$TARGET_IPV4" ]] || die "固定 IP 不能与代理主机相同。"
fi

CURRENT_IPV4="$(current_ipv4 "$NETWORK_INTERFACE")"
if [[ "$CURRENT_IPV4" != "$TARGET_IPV4" ]]; then
  require_command arping
  set +e
  arping -D -I "$NETWORK_INTERFACE" -c 2 -w 3 "$TARGET_IPV4" >"/tmp/vub-arping.$$.log" 2>&1
  ARPING_CODE="$?"
  set -e
  if (( ARPING_CODE != 0 )); then
    tail -n 20 "/tmp/vub-arping.$$.log" >&2 || true
    rm -f "/tmp/vub-arping.$$.log"
    die "检测到 $TARGET_IPV4 可能已被占用。"
  fi
  rm -f "/tmp/vub-arping.$$.log"
fi

NETPLAN_FILE="/etc/netplan/90-vmware-ubuntu-bootstrap-static.yaml"
DNS_YAML="$(python3 - "$DNS_SERVERS" <<'PY'
import sys
print(", ".join(sys.argv[1].split()))
PY
)"

{
  cat <<EOF
network:
  version: 2
  ethernets:
    ${NETWORK_INTERFACE}:
      dhcp4: false
      addresses: [${TARGET_IPV4}/${PREFIX_LENGTH}]
      routes:
        - to: default
          via: ${GATEWAY_IPV4}
      nameservers:
        addresses: [${DNS_YAML}]
EOF
} | write_managed_file "$NETPLAN_FILE" 0600 root root

run netplan generate

if is_dry_run; then
  info "DRY-RUN: netplan try --timeout 120"
else
  [[ -r /dev/tty ]] || die "netplan try 需要交互式控制台。"
  warn "即将切换到 ${TARGET_IPV4}/${PREFIX_LENGTH}。netplan 会在 120 秒未确认时自动回滚。"
  netplan try --timeout 120 </dev/tty >/dev/tty 2>&1 \
    || die "netplan try 未确认或应用失败，网络应已自动回滚。"

  ip -4 addr show dev "$NETWORK_INTERFACE" | grep -Fq "${TARGET_IPV4}/${PREFIX_LENGTH}" \
    || die "固定 IP 应用后复验失败。"
  ip -4 route show default | grep -Fq "via ${GATEWAY_IPV4}" || die "默认网关复验失败。"
  getent hosts github.com >/dev/null 2>&1 || die "固定网络后的 DNS 复验失败。"
  if load_proxy_state; then
    curl -fsSI --connect-timeout 5 --max-time 15 https://github.com/ >/dev/null \
      || die "固定网络后的代理 HTTPS 复验失败。"
  fi
fi

complete_backup
record_reboot_required
mark_phase complete "ip=${TARGET_IPV4}/${PREFIX_LENGTH};gateway=$GATEWAY_IPV4"
info "固定网络阶段完成。"
