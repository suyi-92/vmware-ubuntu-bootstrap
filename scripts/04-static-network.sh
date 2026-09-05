#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "static-network"
# A config/previous phase backup inherited from the entrypoint is not this transaction.
VUB_BACKUP_DIR=""
export VUB_BACKUP_DIR
require_root
load_config false
validate_bool CONFIGURE_STATIC_NETWORK
resolve_real_user

if ! is_true "$CONFIGURE_STATIC_NETWORK"; then
  show_network_state
  # Preserve earlier pending/complete state and the configuration on disk.
  [[ -f "$VUB_STATE_DIR/static-network.state" ]] || mark_phase skipped "keeping existing network"
  exit 0
fi

validate_static_network
NETWORK_INTERFACE=$(current_interface) || die "请选择明确的管理网卡。"
CURRENT_CIDR=$(current_ipv4_cidr "$NETWORK_INTERFACE")
MANAGEMENT_MAC=$(current_mac "$NETWORK_INTERFACE")
check_static_conflicts
require_command netplan

NETPLAN_DIR="${VUB_NETPLAN_DIR:-/etc/netplan}"
NETPLAN_FILE="${VUB_NETPLAN_FILE:-$NETPLAN_DIR/90-vmware-ubuntu-bootstrap-static.yaml}"
# Runtime/vendor definitions cannot safely be rewritten persistently here.
for extra_dir in "${VUB_NETPLAN_RUN_DIR:-/run/netplan}" "${VUB_NETPLAN_LIB_DIR:-/lib/netplan}"; do
  if compgen -G "$extra_dir/*.yaml" >/dev/null || compgen -G "$extra_dir/*.yml" >/dev/null; then
    die "发现 $extra_dir 中的 Netplan 定义；请管理员整合到 /etc/netplan 后再配置静态网络。"
  fi
done

PLAN_DIR=$(mktemp -d)
NETWORK_COMMITTED=false
network_cleanup() {
  local code=$? failed_backup="$VUB_BACKUP_DIR"
  trap - EXIT HUP INT TERM
  if ((code != 0)) && ! is_dry_run && ! is_true "$NETWORK_COMMITTED" && [[ -n "$VUB_BACKUP_DIR" ]]; then
    warn "恢复静态网络阶段修改前的文件。"
    VUB_BACKUP_DIR="" bash "$SCRIPT_DIR/10-rollback.sh" --backup "$failed_backup" --automatic \
      || warn "恢复失败；请在 VMware 控制台按 docs/recovery.md 恢复备份。"
  fi
  rm -rf -- "$PLAN_DIR"
  exit "$code"
}
trap network_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
python3 "$SCRIPT_DIR/network_config.py" plan "$NETPLAN_DIR" "$NETPLAN_FILE" \
  "$NETWORK_INTERFACE" "$MANAGEMENT_MAC" "$STATIC_IPV4_CIDR" "$GATEWAY_IPV4" "$DNS_SERVERS" "$PLAN_DIR" \
  >"$PLAN_DIR/changes" || die "无法生成仅针对管理接口的 Netplan 配置。"

if is_dry_run; then
  info "DRY-RUN: 计划为 $NETWORK_INTERFACE 配置 $STATIC_IPV4_CIDR；不写配置、不执行 netplan 或 ARP。"
  exit 0
fi

if [[ ! -s "$PLAN_DIR/changes" ]] && ! static_network_is_live \
    && grep -q '^status=pending-reboot$' "$VUB_STATE_DIR/static-network.state" 2>/dev/null; then
  info "相同配置仍待重启；保留原备份和 pending-reboot 状态。"
  show_network_state
  NETWORK_COMMITTED=true
  exit 0
fi

if [[ ! -s "$PLAN_DIR/changes" ]] && static_network_is_live; then
  validate_managed_netplan_file
  info "相同静态配置已在所选网卡上生效；没有新增网络配置。"
  mark_phase complete "ip=$STATIC_IPV4_CIDR;gateway=$GATEWAY_IPV4"
  NETWORK_COMMITTED=true
  exit 0
fi

backup_path "$VUB_STATE_DIR/static-network.state"
backup_path "$VUB_STATE_DIR/reboot-required"
while IFS=$'\t' read -r path staged; do
  [[ -n "$path" ]] || continue
  write_managed_file "$path" 0600 root root <"$staged"
done <"$PLAN_DIR/changes"
netplan generate || die "Netplan 语法校验失败。"

if [[ -n "${SSH_CONNECTION:-}" ]]; then
  record_reboot_required
  mark_phase pending-reboot "ip=$STATIC_IPV4_CIDR;gateway=$GATEWAY_IPV4;activation=reboot"
  complete_backup
  NETWORK_COMMITTED=true
  info "静态配置仅写入磁盘；当前地址 $CURRENT_CIDR；待生效地址 $STATIC_IPV4_CIDR。"
  info "重启后连接：ssh -p $SSH_PORT $REAL_USER@${STATIC_IPV4_CIDR%/*}"
  warn "重启后生效没有自动回滚保证。重启前可撤销：sudo bash install.sh --rollback $(basename "$VUB_BACKUP_DIR")"
  exit 0
fi

[[ -r /dev/tty ]] || die "netplan try 需要交互式控制台。"
warn "即将切换到 $STATIC_IPV4_CIDR；请在 120 秒内确认 netplan try。"
netplan try --timeout 120 </dev/tty >/dev/tty 2>&1 || die "netplan try 未确认或应用失败。"
static_network_is_live || die "静态地址或所选接口的默认网关复验失败。"
getent hosts github.com >/dev/null 2>&1 || die "DNS 复验失败。"
if load_proxy_state; then
  curl -fsSI --connect-timeout 5 --max-time 15 https://github.com/ >/dev/null || die "代理 HTTPS 复验失败。"
fi
mark_phase complete "ip=$STATIC_IPV4_CIDR;gateway=$GATEWAY_IPV4"
complete_backup
NETWORK_COMMITTED=true
info "静态网络已应用并通过地址、网关和连通性检查。"
