#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "sudo-policy"
require_root
load_config true
resolve_real_user
validate_config
require_command visudo

SUDOERS_FILE="${VUB_PASSWORDLESS_SUDOERS_FILE:-/etc/sudoers.d/90-vmware-ubuntu-bootstrap-passwordless}"

if is_true "$ENABLE_PASSWORDLESS_SUDO"; then
  sudoers_tmp="$(mktemp)"
  render_passwordless_sudoers "$REAL_USER" >"$sudoers_tmp"
  visudo -cf "$sudoers_tmp" >/dev/null
  write_managed_file "$SUDOERS_FILE" 0440 root root <"$sudoers_tmp"
  rm -f "$sudoers_tmp"

  if ! is_dry_run; then
    visudo -cf /etc/sudoers >/dev/null
    [[ "$(stat -c '%U:%G:%a' "$SUDOERS_FILE")" == "root:root:440" ]] \
      || die "免密 sudoers 文件权限不正确：$SUDOERS_FILE"
    runuser -u "$REAL_USER" -- sudo -n true \
      || die "免密 sudo 复验失败：$REAL_USER"
  fi
  info "已为 $REAL_USER 开启免密 sudo。"
else
  remove_managed_path "$SUDOERS_FILE"
  if ! is_dry_run; then
    visudo -cf /etc/sudoers >/dev/null
  fi
  info "未开启免密 sudo；已移除本项目管理的对应规则。"
fi

complete_backup
mark_phase complete "user=$REAL_USER;passwordless=$ENABLE_PASSWORDLESS_SUDO"
info "sudo 策略阶段完成。"
