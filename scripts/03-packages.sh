#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "packages"
require_root
load_config true
resolve_real_user
load_proxy_state || warn "尚无持久化代理状态；APT 将使用当前环境或直连。"

require_command apt-get

PACKAGES=(
  git curl wget ca-certificates openssh-server
  open-vm-tools open-vm-tools-desktop
  jq python3 python3-venv python3-pip pipx
  build-essential pkg-config
  unzip zip tar rsync
  gnupg lsb-release software-properties-common
  iproute2 iputils-ping iputils-arping dnsutils traceroute
  net-tools ethtool
  vim nano tmux htop tree ripgrep fd-find git-lfs bash-completion shellcheck ufw
)

if is_true "$INSTALL_DOCKER"; then
  PACKAGES+=(docker.io)
fi

run_logged "APT 更新索引" env DEBIAN_FRONTEND=noninteractive apt-get update
run_logged "安装常用软件包" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PACKAGES[@]}"

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
  run systemctl enable --now docker
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

complete_backup
record_reboot_required
mark_phase complete "packages=${#PACKAGES[@]}"
info "软件包阶段完成。"
