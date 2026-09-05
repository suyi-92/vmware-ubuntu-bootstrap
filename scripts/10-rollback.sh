#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

BACKUP_REF="last"
AUTOMATIC="false"

while (( $# > 0 )); do
  case "$1" in
    --backup) BACKUP_REF="${2:-}"; shift 2 ;;
    --automatic) AUTOMATIC="true"; shift ;;
    -h|--help)
      echo "用法：sudo bash 10-rollback.sh --backup <last|backup-id|absolute-path>"
      exit 0
      ;;
    *) die "未知 rollback 参数：$1" ;;
  esac
done

require_root
load_config false
resolve_real_user

resolve_backup() {
  local ref="$1" candidate
  if [[ "$ref" == "last" ]]; then
    [[ -r "$VUB_STATE_DIR/last-backup" ]] || die "没有 last-backup 记录。"
    candidate="$(<"$VUB_STATE_DIR/last-backup")"
  elif [[ "$ref" == /* ]]; then
    candidate="$ref"
  else
    candidate="$VUB_BACKUP_ROOT/$ref"
  fi
  candidate="$(readlink -f -- "$candidate")"
  [[ "$candidate" == "$VUB_BACKUP_ROOT/"* && "$candidate" != "$VUB_BACKUP_ROOT" ]] \
    || die "备份路径不在受管目录内：$candidate"
  [[ -d "$candidate" && -f "$candidate/paths.tsv" ]] || die "备份不完整：$candidate"
  printf '%s\n' "$candidate"
}

SOURCE_BACKUP="$(resolve_backup "$BACKUP_REF")"
SOURCE_PHASE="$(sed -nE 's/^phase=(.*)$/\1/p' "$SOURCE_BACKUP/MANIFEST.txt" | head -n1)"
[[ -n "$SOURCE_PHASE" ]] || SOURCE_PHASE="unknown"

if ! is_true "$AUTOMATIC" && ! is_true "$VUB_YES"; then
  init_input_tty
  read_yes_no "确认回滚备份 $(basename "$SOURCE_BACKUP")（阶段 $SOURCE_PHASE）" no \
    || die "用户取消回滚。"
fi

POWER_STATE_COPY=""
TIME_STATE_COPY=""
SNAP_STATE_COPY=""
if [[ "$SOURCE_PHASE" == "power" && -r "$VUB_ETC_DIR/power.previous" ]]; then
  POWER_STATE_COPY="$(mktemp)"
  cp -a "$VUB_ETC_DIR/power.previous" "$POWER_STATE_COPY"
fi
if [[ "$SOURCE_PHASE" == "packages" && -r "$VUB_STATE_DIR/time.previous" ]]; then
  TIME_STATE_COPY="$(mktemp)"
  cp -a "$VUB_STATE_DIR/time.previous" "$TIME_STATE_COPY"
fi
if [[ "$SOURCE_PHASE" == proxy* && -r "$VUB_STATE_DIR/snap-proxy.previous" ]]; then
  SNAP_STATE_COPY="$(mktemp)"
  cp -a "$VUB_STATE_DIR/snap-proxy.previous" "$SNAP_STATE_COPY"
fi
trap 'rm -f "${POWER_STATE_COPY:-}" "${TIME_STATE_COPY:-}" "${SNAP_STATE_COPY:-}"' EXIT

start_phase "rollback-${SOURCE_PHASE}"
require_command tac

while IFS=$'\t' read -r original_state path; do
  [[ -n "$path" ]] || continue
  safe_backup_target "$path" || die "备份清单包含不安全路径：$path"
  [[ "$path" != "$VUB_BACKUP_ROOT" && "$path" != "$VUB_BACKUP_ROOT/"* ]] \
    || die "拒绝从清单修改备份根目录。"
  backup_path "$path"
  if is_dry_run; then
    info "DRY-RUN: restore $original_state $path"
    continue
  fi
  case "$original_state" in
    present)
      source_path="$SOURCE_BACKUP/rootfs/${path#/}"
      [[ -e "$source_path" || -L "$source_path" ]] || die "备份内容缺失：$source_path"
      rm -rf -- "$path"
      mkdir -p "$(dirname "$path")"
      cp -a -- "$source_path" "$path"
      ;;
    absent)
      rm -rf -- "$path"
      ;;
    *) die "未知备份状态：$original_state" ;;
  esac
done < <(tac "$SOURCE_BACKUP/paths.tsv")

if ! is_dry_run; then
  systemctl daemon-reload 2>/dev/null || true
  if [[ "$SOURCE_PHASE" == "power" && -n "$POWER_STATE_COPY" ]]; then
    idle_delay=""
    lock_enabled=""
    ac_sleep_type=""
    # shellcheck disable=SC1090
    source "$POWER_STATE_COPY"
    if [[ -n "${idle_delay:-}" ]] && command -v gsettings >/dev/null 2>&1; then
      run_as_user_with_bus gsettings set org.gnome.desktop.session idle-delay "$idle_delay" || true
      run_as_user_with_bus gsettings set org.gnome.desktop.screensaver lock-enabled "$lock_enabled" || true
      run_as_user_with_bus gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "$ac_sleep_type" || true
    fi
  fi
  if [[ "$SOURCE_PHASE" == "packages" && -n "$TIME_STATE_COPY" ]]; then
    timezone=""
    ntp=""
    # shellcheck disable=SC1090
    source "$TIME_STATE_COPY"
    if [[ -n "$timezone" ]]; then
      timedatectl set-timezone "$timezone" || true
    fi
    if [[ "$ntp" == "yes" ]]; then
      timedatectl set-ntp true || true
    else
      timedatectl set-ntp false || true
    fi
    if [[ -s /etc/hostname ]]; then
      hostnamectl set-hostname "$(< /etc/hostname)" || true
    fi
    warn "已恢复受管配置，但不会自动卸载 packages 阶段安装的软件包。"
  fi
  if [[ "$SOURCE_PHASE" == proxy* && -n "$SNAP_STATE_COPY" ]] && command -v snap >/dev/null 2>&1; then
    previous_http=""
    previous_https=""
    # shellcheck disable=SC1090
    source "$SNAP_STATE_COPY"
    if [[ -n "$previous_http" && "$previous_http" != "null" ]]; then
      snap set system proxy.http="$previous_http" || true
    else
      snap unset system proxy.http || true
    fi
    if [[ -n "$previous_https" && "$previous_https" != "null" ]]; then
      snap set system proxy.https="$previous_https" || true
    else
      snap unset system proxy.https || true
    fi
  fi

  case "$SOURCE_PHASE" in
    static-network)
      netplan generate
      if [[ -n "${SSH_CONNECTION:-}" ]]; then
        warn "网络文件已恢复；SSH 会话不立即应用。请核对磁盘配置后在控制台应用或重启。"
      else
        netplan apply
      fi
      ;;
    ssh)
      sshd_bin="${VUB_SSHD_BIN:-/usr/sbin/sshd}"
      "$sshd_bin" -t
      systemctl daemon-reload
      if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
      else
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      fi
      ufw reload 2>/dev/null || true
      ;;
    proxy|proxy-*)
      systemctl daemon-reexec
      if systemctl is-active --quiet docker 2>/dev/null; then
        systemctl restart docker || true
      fi
      ;;
  esac
fi

complete_backup
mark_phase complete "restored=$(basename "$SOURCE_BACKUP")"
info "回滚完成：$(basename "$SOURCE_BACKUP")；安全快照已保留，可再次回退。"
