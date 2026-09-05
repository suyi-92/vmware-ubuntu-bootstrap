#!/usr/bin/env bash

normalize_static_address() {
  STATIC_IPV4_CIDR=$(python3 "$VUB_SCRIPT_DIR/network_config.py" address \
    "$STATIC_IPV4_CIDR" "$STATIC_IPV4_PREFIX" "$STATIC_IPV4_LAST_OCTET" "$PREFIX_LENGTH") \
    || die "静态地址配置无效。"
}

validate_static_network() {
  local normalized
  normalized=$(python3 "$VUB_SCRIPT_DIR/network_config.py" validate \
    "$STATIC_IPV4_CIDR" "$GATEWAY_IPV4" "$DNS_SERVERS") || die "固定网络参数校验失败。"
  local -a fields
  mapfile -t fields <<<"$normalized"
  STATIC_IPV4_CIDR=${fields[0]}; GATEWAY_IPV4=${fields[1]}; DNS_SERVERS=${fields[2]}
}

network_field() {
  local data
  data=$(python3 "$VUB_SCRIPT_DIR/network_config.py" inspect "${2:-${NETWORK_INTERFACE:-}}") || return 1
  sed -n "${1}p" <<<"$data"
}
current_interface() { network_field 1 "${NETWORK_INTERFACE:-}"; }
current_ipv4_cidr() { network_field 2 "${1:-}"; }
current_ipv4() { local cidrs; cidrs=$(current_ipv4_cidr "${1:-}") || return 1; printf '%s\n' "${cidrs%%/*}"; }
current_gateway() { network_field 3 "${1:-}"; }
current_mac() { network_field 4 "${1:-}"; }

current_dns_servers() {
  local iface="${1:-$(current_interface)}"
  # resolv.conf may contain a global stub or DNS for a VPN, not this interface.
  resolvectl dns "$iface" 2>/dev/null | sed -E 's/^.*:[[:space:]]*//' | xargs
}

management_cidrs() {
  local cidrs
  cidrs=$(current_ipv4_cidr "${NETWORK_INTERFACE:-}") || return 1
  if is_true "$CONFIGURE_STATIC_NETWORK" && [[ -n "$STATIC_IPV4_CIDR" ]]; then cidrs+=" $STATIC_IPV4_CIDR"; fi
  python3 - "$cidrs" <<'PY'
import ipaddress, sys
for net in dict.fromkeys(str(ipaddress.ip_interface(x).network) for x in sys.argv[1].split()):
    print(net)
PY
}

default_proxy_scan_cidr() {
  local cidrs
  cidrs=$(current_ipv4_cidr "${1:-}") || return 1
  python3 - "$cidrs" <<'PY'
import ipaddress, sys
items = sys.argv[1].split()
if len(items) != 1:
    raise SystemExit("代理自动扫描需要唯一当前 IPv4，或明确配置 PROXY_SCAN_CIDR")
iface = ipaddress.IPv4Interface(items[0])
# Bound discovery independently of the network prefix. Never scan a /16.
print(ipaddress.IPv4Network(f"{iface.ip}/{max(24, iface.network.prefixlen)}", strict=False))
PY
}

show_network_state() {
  local iface
  iface=$(current_interface) || { warn "管理网卡不明确；请设置 NETWORK_INTERFACE。"; return 1; }
  info "当前网络：$iface；IPv4/CIDR=$(current_ipv4_cidr "$iface")；网关=$(current_gateway "$iface")；MAC=$(current_mac "$iface")"
  if is_true "$CONFIGURE_STATIC_NETWORK"; then
    info "请求的静态地址：$STATIC_IPV4_CIDR；网关=$GATEWAY_IPV4；DNS=$DNS_SERVERS"
  else
    info "保持现有网络；可在路由器上按各 VM 的独立 MAC 配置 DHCP 地址保留。"
  fi
  if [[ -r "$VUB_STATE_DIR/static-network.state" ]]; then
    info "已有网络阶段状态：$(sed -n '/^status=/p; /^detail=/p' "$VUB_STATE_DIR/static-network.state")"
  fi
  if [[ -e "${VUB_NETPLAN_FILE:-${VUB_NETPLAN_DIR:-/etc/netplan}/90-vmware-ubuntu-bootstrap-static.yaml}" ]]; then
    warn "磁盘仍有本项目静态配置；保持模式不会删除它，重启可能应用该配置。"
    info "如需撤销，请显式运行：sudo bash install.sh --rollback <static-network 备份 ID>（见 docs/recovery.md）。"
  fi
}

check_static_conflicts() {
  local target=${STATIC_IPV4_CIDR%/*} saved_proxy="" output code=0
  if [[ -r "$VUB_ETC_DIR/proxy.env" ]]; then
    saved_proxy=$(source "$VUB_ETC_DIR/proxy.env"; printf '%s' "${VUB_PROXY_HOST:-}")
  fi
  python3 "$VUB_SCRIPT_DIR/network_config.py" conflicts "$STATIC_IPV4_CIDR" "$NETWORK_INTERFACE" \
    "$PROXY_HOST" "$saved_proxy" || die "目标地址存在明确冲突，或无法核实代理地址。"
  if is_dry_run; then
    info "DRY-RUN: 将在 $NETWORK_INTERFACE 上执行 iputils arping -D；尚未验证地址空闲。"
    return 0
  fi
  require_command arping
  LC_ALL=C arping -V 2>&1 | grep -qi iputils || die "ARP 检测仅支持 iputils-arping；当前实现无法可靠判断退出码。"
  # iputils DAD uses source 0.0.0.0 and ignores packets from our own MAC.
  # Run even when already configured: other hosts claiming our address still matter.
  output=$(LC_ALL=C timeout 8 arping -D -I "$NETWORK_INTERFACE" -c 2 -w 3 "$target" 2>&1) || code=$?
  case "$code" in
    0)
      if ! grep -Eq '^Sent 2 probes ' <<<"$output" || ! grep -Eq '^Received 0 response' <<<"$output"; then
        die "ARP 没有返回完整探测结果，不能确认地址空闲。"
      fi
      ;;
    1)
      if grep -Eq 'Received [1-9][0-9]* response' <<<"$output"; then
        die "ARP 检测发现重复地址：$target；--yes 不能绕过。"
      fi
      die "ARP 探测失败，无法确认地址空闲；请检查接口、权限和链路。"
      ;;
    *) die "ARP 工具执行错误（退出码 $code），无法确认地址空闲。" ;;
  esac
}

static_network_is_live() {
  local cidrs gateway
  cidrs=$(current_ipv4_cidr "$NETWORK_INTERFACE") || return 1
  gateway=$(current_gateway "$NETWORK_INTERFACE") || return 1
  [[ " $cidrs " == *" $STATIC_IPV4_CIDR "* && "$gateway" == "$GATEWAY_IPV4" ]]
}

validate_managed_netplan_file() {
  local path="${VUB_NETPLAN_FILE:-${VUB_NETPLAN_DIR:-/etc/netplan}/90-vmware-ubuntu-bootstrap-static.yaml}"
  [[ -f "$path" && ! -L "$path" ]] || die "受管 Netplan 配置不存在或不是普通文件。"
  [[ "$(stat -c '%U:%G:%a' "$path")" == root:root:600 ]] || die "受管 Netplan 配置权限必须为 root:root:600。"
}
