#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"
# shellcheck source=apt-repositories.sh
source "$SCRIPT_DIR/apt-repositories.sh"

start_phase "packages"
require_root
load_config true
resolve_real_user
validate_config
load_proxy_state || warn "尚无持久化代理状态；APT 将使用当前环境或直连。"

require_command apt-get

install_missing_apt_packages "安装 APT 软件源管理依赖" \
  ca-certificates curl gnupg

if is_true "$ENABLE_UPSTREAM_APT_SOURCES"; then
  info "配置 GitHub CLI、Git/Git LFS、Kitware 与 Docker（如启用）软件源。"
  configure_upstream_apt_sources
else
  info "未启用上游 APT 源，将使用 Ubuntu 24.04 仓库版本。"
  remove_upstream_apt_sources
fi

run_logged "更新全部 APT 软件源索引" \
  env DEBIAN_FRONTEND=noninteractive apt-get update
if is_true "$UPGRADE_INSTALLED_PACKAGES"; then
  upgrade_installed_apt_packages
fi

PACKAGES=(
  git gh git-lfs curl wget ca-certificates openssh-server
  open-vm-tools open-vm-tools-desktop
  nodejs npm node-gyp
  jq python3 python3-venv python3-pip python3-dev pipx
  build-essential pkg-config
  unzip zip tar xz-utils rsync findutils diffutils
  gnupg lsb-release software-properties-common
  iproute2 iputils-ping iputils-arping dnsutils traceroute
  net-tools ethtool procps
  vim nano tmux htop tree ripgrep fd-find bash-completion shellcheck ufw
)

# mdd-sim-gateway 的正式 Linux 安装链会在宿主机编译 pcsc-lite、CCID/vpcd、
# pyscard 和 lpac；Engine 与 WebUI 仍由 Docker 构建，宿主机 Node/npm 用于
# WebUI 本地开发和 npm 原生模块构建。
MDD_BUILD_PACKAGES=(
  autoconf automake cmake flex help2man libtool meson ninja-build patch perl swig
  libccid pcscd pcsc-tools vsmartcard-vpcd
  libpcsclite-dev libudev-dev libsystemd-dev libusb-1.0-0-dev zlib1g-dev
  libffi-dev libssl-dev libcurl4-openssl-dev openssl
  modemmanager network-manager dbus udev usbutils
)
PACKAGES+=("${MDD_BUILD_PACKAGES[@]}")

if is_true "$CONFIGURE_CODEX"; then
  PACKAGES+=(bubblewrap apparmor-profiles apparmor-utils)
fi

if is_true "$INSTALL_DOCKER"; then
  if is_true "$ENABLE_UPSTREAM_APT_SOURCES"; then
    PACKAGES+=(
      docker-ce docker-ce-cli containerd.io
      docker-buildx-plugin docker-compose-plugin
    )
    if dpkg-query -W -f='${Status}\n' docker.io 2>/dev/null \
        | grep -Fxq 'install ok installed'; then
      warn "检测到 Ubuntu docker.io；APT 将原子迁移到 Docker CE，现有 /var/lib/docker 数据不会被主动删除。"
    fi
  else
    PACKAGES+=(docker.io)
  fi
fi

install_or_upgrade_apt_packages "安装或升级常用、运行与构建软件包" "${PACKAGES[@]}"

run_as_user git lfs install --skip-repo

if is_dry_run; then
  info "DRY-RUN: verify gh, Git LFS, CMake, Node.js, npm and npx"
else
  command -v gh >/dev/null 2>&1 || die "GitHub CLI 安装失败。"
  git lfs version >/dev/null 2>&1 || die "Git LFS 安装失败。"
  cmake --version >/dev/null 2>&1 || die "CMake 安装失败。"
  node --version >/dev/null 2>&1 || die "Node.js 安装失败。"
  npm --version >/dev/null 2>&1 || die "npm 安装失败。"
  npx --version >/dev/null 2>&1 || die "npx 安装失败。"
fi

if is_dry_run; then
  info "DRY-RUN: verify open-vm-tools desktop clipboard integration"
else
  for vmware_package in open-vm-tools open-vm-tools-desktop; do
    dpkg-query -W -f='${Status}\n' "$vmware_package" 2>/dev/null \
      | grep -Fxq 'install ok installed' \
      || die "VMware 集成包安装失败：$vmware_package"
  done
  command -v vmware-user-suid-wrapper >/dev/null 2>&1 \
    || die "open-vm-tools-desktop 已安装，但缺少 vmware-user-suid-wrapper。"
  [[ -r /etc/xdg/autostart/vmware-user.desktop ]] \
    || warn "未找到 VMware 桌面代理自动启动项；主机与虚拟机复制粘贴可能不可用。"
fi

if [[ -n "$HOSTNAME" && "$HOSTNAME" != "$(hostname)" ]]; then
  backup_path /etc/hostname
  backup_path /etc/hosts
  run hostnamectl set-hostname "$HOSTNAME"
fi

if command -v timedatectl >/dev/null 2>&1; then
  timedatectl list-timezones | grep -Fxq "$TIMEZONE" || die "无效时区：$TIMEZONE"
  if [[ ! -f "$VUB_STATE_DIR/time.previous" ]] && ! is_dry_run; then
    {
      printf 'timezone=%q\n' "$(timedatectl show -p Timezone --value 2>/dev/null || true)"
      printf 'ntp=%q\n' "$(timedatectl show -p NTP --value 2>/dev/null || true)"
    } | write_managed_file "$VUB_STATE_DIR/time.previous" 0600 root root
  fi
  run timedatectl set-timezone "$TIMEZONE"
  run timedatectl set-ntp true
fi

if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
  run systemctl enable --now ssh.socket
else
  run systemctl enable --now ssh.service
fi
if systemctl list-unit-files open-vm-tools.service 2>/dev/null | grep -q '^open-vm-tools\.service'; then
  run systemctl enable --now open-vm-tools
fi

if is_true "$INSTALL_DOCKER"; then
  if is_true "$ENABLE_UPSTREAM_APT_SOURCES" && ! is_dry_run; then
    for docker_package in docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin; do
      dpkg-query -W -f='${Status}\n' "$docker_package" 2>/dev/null \
        | grep -Fxq 'install ok installed' \
        || die "Docker 官方软件包安装失败：$docker_package"
    done
  fi
  # Docker CE 通过 -H fd:// 从 docker.socket 获取 API listener。docker.io
  # 迁移后显式 reload 并先启动 socket，避免 service 找不到 listener。
  activate_docker_runtime
  if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -Fxq docker; then
    run usermod -aG docker "$REAL_USER"
    warn "已把 $REAL_USER 加入 docker 组；重新登录后生效。"
  fi
fi

if [[ -x /usr/bin/fdfind && ! -e "$REAL_HOME/.local/bin/fd" ]]; then
  backup_path "$REAL_HOME/.local/bin/fd"
  if is_dry_run; then
    info "DRY-RUN: create fd -> /usr/bin/fdfind"
  else
    install -d -m 0755 -o "$REAL_USER" -g "$REAL_GROUP" "$REAL_HOME/.local/bin"
    ln -s /usr/bin/fdfind "$REAL_HOME/.local/bin/fd"
    chown -h "$REAL_USER:$REAL_GROUP" "$REAL_HOME/.local/bin/fd"
  fi
fi

if is_true "$INSTALL_DOCKER" && [[ -r "$VUB_ETC_DIR/proxy.env" ]]; then
  # shellcheck disable=SC1090
  source "$VUB_ETC_DIR/proxy.env"
  VUB_FORCE_PROXY_HOST="${VUB_PROXY_HOST:-}"
  export VUB_FORCE_PROXY_HOST
  info "Docker 安装完成，重新应用代理以覆盖 Docker daemon/client。"
  VUB_BACKUP_DIR="" VUB_PHASE_NAME="proxy-post-docker" bash "$SCRIPT_DIR/02-proxy.sh" apply
fi

if is_true "$INSTALL_DOCKER"; then
  # 代理阶段会重载并重启 Docker；只有最终存活检查通过才能完成阶段。
  verify_docker_runtime
  if ! is_dry_run && ! run_as_user docker info >/dev/null 2>&1; then
    die "用户 $REAL_USER 无法访问 Docker daemon。"
  fi
fi

complete_backup
record_reboot_required
mark_phase complete \
  "packages=${#PACKAGES[@]};upstream_sources=$ENABLE_UPSTREAM_APT_SOURCES;system_upgrade=$UPGRADE_INSTALLED_PACKAGES"
info "软件包阶段完成。"
