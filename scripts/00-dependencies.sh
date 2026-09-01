#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "dependencies"
require_root

OS_RELEASE_FILE="${VUB_OS_RELEASE_FILE:-/etc/os-release}"
[[ -r "$OS_RELEASE_FILE" ]] || die "无法读取 $OS_RELEASE_FILE"
# shellcheck disable=SC1090
source "$OS_RELEASE_FILE"
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
  || die "首版只支持 Ubuntu 24.04，当前：${PRETTY_NAME:-unknown}"

# 这里只安装自动发现并写入代理所需的最小依赖。完整开发、Docker、VMware、
# SSH 与 MDD 构建依赖会在代理生效后的 packages 阶段按缺失项安装。
STARTUP_PACKAGES=(
  bash coreutils mawk sed grep
  ca-certificates curl git wget
  python3 iproute2
  sudo util-linux libc-bin systemd
)

install_missing_apt_packages "安装启动依赖" "${STARTUP_PACKAGES[@]}"

for cmd in bash awk sed grep install stat sha256sum ip curl git wget python3 \
  systemctl getent runuser visudo; do
  require_command "$cmd"
done

mark_phase complete "packages=${#STARTUP_PACKAGES[@]};missing=${VUB_LAST_MISSING_PACKAGE_COUNT:-0}"
info "启动依赖检查完成。"
