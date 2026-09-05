#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "preflight"
require_root
load_config true
resolve_real_user
validate_config
if is_true "$INSTALL_DOCKER"; then select_docker_source || die "请先诊断已有 Docker。"; fi

OS_RELEASE_FILE="${VUB_OS_RELEASE_FILE:-/etc/os-release}"
[[ -r "$OS_RELEASE_FILE" ]] || die "无法读取 $OS_RELEASE_FILE"
# shellcheck disable=SC1090
source "$OS_RELEASE_FILE"
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
  || die "首版只支持 Ubuntu 24.04，当前：${PRETTY_NAME:-unknown}"

for cmd in bash awk sed grep install stat sha256sum ip curl python3 systemctl getent runuser; do
  require_command "$cmd"
done

[[ -n "$NETWORK_INTERFACE" ]] || NETWORK_INTERFACE="$(current_interface)"
[[ -n "$NETWORK_INTERFACE" ]] || die "无法确定默认路由网卡。"
ip link show dev "$NETWORK_INTERFACE" >/dev/null 2>&1 || die "网卡不存在：$NETWORK_INTERFACE"

CURRENT_IP="$(current_ipv4 "$NETWORK_INTERFACE")"
CURRENT_GATEWAY="$(current_gateway "$NETWORK_INTERFACE")"
[[ -n "$CURRENT_IP" ]] || die "网卡 $NETWORK_INTERFACE 没有全局 IPv4。"
[[ -n "$CURRENT_GATEWAY" ]] || die "没有 IPv4 默认路由。"

AVAILABLE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
[[ "$AVAILABLE_KB" =~ ^[0-9]+$ ]] || die "无法读取根文件系统剩余空间。"
(( AVAILABLE_KB >= 1048576 )) || die "根文件系统剩余空间不足 1 GiB。"

if [[ -n "${SSH_CONNECTION:-}" ]] && is_true "$CONFIGURE_STATIC_NETWORK"; then
  warn "当前会话来自 SSH；固定网络配置将写入磁盘并在重启时生效，当前连接不会中断。"
fi

info "系统：${PRETTY_NAME}"
info "目标用户：$REAL_USER ($REAL_HOME)"
show_network_state
info "根文件系统剩余：$((AVAILABLE_KB / 1024)) MiB"

mark_phase complete "os=${ID}:${VERSION_ID};iface=$NETWORK_INTERFACE;ip=$CURRENT_IP"
info "预检通过。"
