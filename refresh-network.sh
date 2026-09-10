#!/usr/bin/env bash
# Run from the existing checkout; recovery must not depend on Git or APT access.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/00-lib.sh
source "$PROJECT_DIR/scripts/00-lib.sh"

usage() {
  cat <<'EOF'
宿主机切换 Wi-Fi 后刷新 Ubuntu 桥接网络与宿主代理：
  sudo bash refresh-network.sh                     # 当前地址已更新：重新发现代理
  sudo bash refresh-network.sh --renew             # 在 VMware 控制台重连 DHCP，再刷新代理
  sudo bash refresh-network.sh --proxy-host 192.168.2.100

选项：
  --interface NAME     管理网卡；默认沿用配置或唯一物理默认路由网卡
  --connection UUID    --renew 时使用的已有 NetworkManager 连接（无活动连接时必填）
  --proxy-host IPv4    显式指定 Windows 代理主机；默认扫描当前 /24 或更小网段
  --proxy-port PORT    代理端口；默认使用原配置，未配置时为 7890
  --config FILE        原安装配置，默认项目中的 config.env
  --dry-run            预览；不重连、不写系统配置，但会探测当前网络中的代理
  --renew              仅重连已有 DHCP 连接；不把静态网络改成 DHCP，不支持 SSH 会话
  -h, --help           显示帮助

代理刷新会更新本项目管理的 Shell/APT/Git/systemd/Docker/Snap 和 GNOME 桌面配置。
代理发生变化时会重启正在运行的 Docker；已运行的其他程序需重新启动。
EOF
}

ORIGINAL_ARGS=("$@")
RENEW=false
SELECTED_INTERFACE=""
CONNECTION_UUID=""
SELECTED_PROXY_HOST=""
SELECTED_PROXY_PORT=""
while (( $# > 0 )); do
  case "$1" in
    --interface|--connection|--proxy-host|--proxy-port|--config)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 缺少参数。"
      case "$1" in
        --interface) SELECTED_INTERFACE="$2" ;;
        --connection) CONNECTION_UUID="$2" ;;
        --proxy-host) SELECTED_PROXY_HOST="$2" ;;
        --proxy-port) SELECTED_PROXY_PORT="$2" ;;
        --config) VUB_CONFIG_FILE="$2" ;;
      esac
      shift 2 ;;
    --renew) RENEW=true; shift ;;
    --dry-run) VUB_DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）。" ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || die "请在 Ubuntu Linux 中运行。"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo --preserve-env=SSH_CONNECTION,SSH_CLIENT,SSH_TTY bash "$0" "${ORIGINAL_ARGS[@]}"
fi
require_root
require_command python3
require_command ip
load_config true
resolve_real_user
[[ ! -e "$VUB_STATE_DIR/active-backup" ]] \
  || die "有未完成的配置备份：$VUB_STATE_DIR/active-backup；请先按 docs/recovery.md 完成恢复。"
validate_port SSH_PORT
[[ -z "$CONNECTION_UUID" || "$RENEW" == true ]] || die "--connection 必须与 --renew 一起使用。"
if [[ -n "$CONNECTION_UUID" ]]; then
  [[ "$CONNECTION_UUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
    || die "--connection 需要连接 UUID；请用 nmcli connection show 查看。"
fi
if [[ -n "$SELECTED_PROXY_HOST" ]]; then
  python3 - "$SELECTED_PROXY_HOST" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
fi
PROXY_PORT="${SELECTED_PROXY_PORT:-$PROXY_PORT}"
validate_port PROXY_PORT
NETWORK_INTERFACE="${SELECTED_INTERFACE:-$NETWORK_INTERFACE}"
NETWORK_INTERFACE=$(current_interface) \
  || die "无法确定管理网卡；用 ip -br link 查看后加 --interface <网卡>。"

in_ssh_session() {
  [[ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] || return 0
  # sudo may have removed SSH_*; also inspect the process ancestry.
  local ancestor=$PPID process_name
  while [[ "$ancestor" =~ ^[0-9]+$ ]] && (( ancestor > 1 )); do
    process_name=$(ps -o comm= -p "$ancestor") || return 0
    [[ "$process_name" != sshd* ]] || return 0
    ancestor=$(ps -o ppid= -p "$ancestor" | tr -d ' ') || return 0
  done
  return 1
}

if is_true "$RENEW"; then
  in_ssh_session && die "--renew 会断开网卡，请在 VMware 的 Ubuntu 本地终端执行。"
  require_command nmcli
  [[ "$(LC_ALL=C nmcli -g GENERAL.TYPE device show "$NETWORK_INTERFACE")" == ethernet ]] \
    || die "仅支持 NetworkManager 管理的桥接以太网卡。"
  if [[ -z "$CONNECTION_UUID" ]]; then
    CONNECTION_UUID=$(LC_ALL=C nmcli -g GENERAL.CON-UUID device show "$NETWORK_INTERFACE")
  fi
  [[ -n "$CONNECTION_UUID" && "$CONNECTION_UUID" != -- ]] \
    || die "网卡没有活动连接；用 nmcli connection show 查找原连接，再加 --connection <UUID>。"
  METHOD=$(LC_ALL=C nmcli -g ipv4.method connection show uuid "$CONNECTION_UUID")
  [[ "$METHOD" == auto ]] \
    || die "当前连接不是 DHCP（ipv4.method=$METHOD）；请按 docs/host-ip-change.md 恢复或调整静态网络。"
  [[ "$(LC_ALL=C nmcli -g connection.type connection show uuid "$CONNECTION_UUID")" == 802-3-ethernet ]] \
    || die "所选连接不是以太网连接。"
  PROFILE_INTERFACE=$(LC_ALL=C nmcli -g connection.interface-name connection show uuid "$CONNECTION_UUID")
  [[ -z "$PROFILE_INTERFACE" || "$PROFILE_INTERFACE" == -- || "$PROFILE_INTERFACE" == "$NETWORK_INTERFACE" ]] \
    || die "所选连接绑定其他网卡：$PROFILE_INTERFACE。"
  PROFILE_MAC=$(LC_ALL=C nmcli -g 802-3-ethernet.mac-address connection show uuid "$CONNECTION_UUID")
  if [[ -n "$PROFILE_MAC" && "$PROFILE_MAC" != -- ]]; then
    CURRENT_MAC=$(current_mac "$NETWORK_INTERFACE")
    [[ "${PROFILE_MAC,,}" == "${CURRENT_MAC,,}" ]] || die "所选连接的 MAC 与管理网卡不匹配。"
  fi
  if is_true "$CONFIGURE_STATIC_NETWORK" || [[ -e "${VUB_NETPLAN_FILE:-${VUB_NETPLAN_DIR:-/etc/netplan}/90-vmware-ubuntu-bootstrap-static.yaml}" ]]; then
    die "仍有本项目静态网络配置；请先按 docs/recovery.md 恢复，避免重启后再次应用旧地址。"
  fi
  if grep -q '^status=pending-reboot$' "$VUB_STATE_DIR/static-network.state" 2>/dev/null; then
    die "仍有待重启的静态网络状态；请先按 docs/recovery.md 核实并恢复对应配置。"
  fi
  info "重连 $NETWORK_INTERFACE 的 DHCP 连接 $CONNECTION_UUID（最长等待 45 秒）。"
  if is_dry_run; then
    info "DRY-RUN: 将断开并重新激活该连接；新地址尚未知，后续代理扫描需在重连后执行。"
    exit 0
  fi
  ACTIVE_UUID=$(LC_ALL=C nmcli -g GENERAL.CON-UUID device show "$NETWORK_INTERFACE")
  if [[ -n "$ACTIVE_UUID" && "$ACTIVE_UUID" != -- ]]; then
    if ! nmcli --wait 10 device disconnect "$NETWORK_INTERFACE"; then
      warn "断开命令未成功返回；仍尝试用已记录的 UUID 重新激活连接。"
    fi
  fi
  if ! nmcli --wait 45 connection up uuid "$CONNECTION_UUID" ifname "$NETWORK_INTERFACE"; then
    die "DHCP 重连失败。检查 VMware 桥接到当前 Wi-Fi、虚拟网卡已连接；修复后重跑本命令（加 --connection $CONNECTION_UUID）。"
  fi
fi

CURRENT_CIDR=$(current_ipv4_cidr "$NETWORK_INTERFACE")
CURRENT_GATEWAY=$(current_gateway "$NETWORK_INTERFACE")
[[ -n "$CURRENT_CIDR" && -n "$CURRENT_GATEWAY" ]] \
  || die "网卡没有 IPv4 或默认网关；请在 VMware 控制台运行本脚本 --renew，或检查桥接设置。"
info "当前网络：$NETWORK_INTERFACE；IPv4/CIDR=$CURRENT_CIDR；网关=$CURRENT_GATEWAY"
export VUB_CONFIG_FILE VUB_DRY_RUN
# Multiple reachable proxies require an explicit --proxy-host, never a default pick.
export VUB_YES=true
export VUB_REFRESH_INTERFACE="$NETWORK_INTERFACE" VUB_FORCE_PROXY_HOST="$SELECTED_PROXY_HOST"
export VUB_REFRESH_PROXY_PORT="$PROXY_PORT"
# Do not install dependencies through a possibly stale proxy during recovery.
bash "$PROJECT_DIR/bootstrap.sh" --phase proxy-refresh --config "$VUB_CONFIG_FILE"

# Refresh only the LAN SSH allowance; do not reinstall SSH or change its keys/settings.
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active'; then
  CONFIGURE_STATIC_NETWORK=false
  LAN_CIDRS=$(management_cidrs)
  [[ -n "$LAN_CIDRS" ]] || die "无法确定 UFW 的新管理网段。"
  VUB_BACKUP_DIR=""
  start_phase network-refresh-ssh
  backup_path /etc/ufw
  while IFS= read -r lan_cidr; do
    run ufw allow from "$lan_cidr" to any port "$SSH_PORT" proto tcp comment 'vmware-ubuntu-bootstrap ssh'
  done <<<"$LAN_CIDRS"
  complete_backup
  info "已处理当前网段的 SSH 放行规则；旧规则保留，请确认新连接可用后再清理。"
fi
if is_dry_run; then
  info "DRY-RUN: 预览完成，系统未修改。"
else
  info "刷新完成。Windows SSH 地址：ssh -p $SSH_PORT $REAL_USER@${CURRENT_CIDR%/*}"
  info "在当前普通用户终端执行：source /etc/profile.d/90-vmware-ubuntu-bootstrap-proxy.sh"
  info "浏览器需完全退出后，从已执行 source 的终端重新启动；桌面会话仍带旧代理时，请注销并重新登录 Ubuntu。"
  info "原 config.env 保留，今后切换 Wi-Fi 继续运行本脚本。"
fi
