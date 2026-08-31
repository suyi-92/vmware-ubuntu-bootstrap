#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "power"
require_root
load_config true
resolve_real_user

POWER_STATE="$VUB_ETC_DIR/power.previous"
if [[ ! -f "$POWER_STATE" ]]; then
  idle="" lock="" ac_sleep=""
  if command -v gsettings >/dev/null 2>&1 && [[ -S "/run/user/${REAL_UID}/bus" ]]; then
    idle="$(run_as_user_with_bus gsettings get org.gnome.desktop.session idle-delay 2>/dev/null || true)"
    lock="$(run_as_user_with_bus gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)"
    ac_sleep="$(run_as_user_with_bus gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || true)"
  fi
  {
    printf 'idle_delay=%s\n' "$(shell_quote "$idle")"
    printf 'lock_enabled=%s\n' "$(shell_quote "$lock")"
    printf 'ac_sleep_type=%s\n' "$(shell_quote "$ac_sleep")"
    for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
      printf '%s=%s\n' "${target//./_}" "$(shell_quote "$(systemctl is-enabled "$target" 2>/dev/null || true)")"
    done
  } | write_managed_file "$POWER_STATE" 0600 root root
fi

if command -v gsettings >/dev/null 2>&1; then
  if run_as_user_with_bus gsettings writable org.gnome.desktop.session idle-delay >/dev/null 2>&1; then
    run_as_user_with_bus gsettings set org.gnome.desktop.session idle-delay 'uint32 0'
    run_as_user_with_bus gsettings set org.gnome.desktop.screensaver lock-enabled false
    run_as_user_with_bus gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
  else
    warn "没有可用的 GNOME DBus 会话，跳过桌面 gsettings；登录桌面后可重跑 power 阶段。"
  fi
else
  warn "未安装 gsettings，跳过 GNOME 桌面项。"
fi

for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  backup_path "/etc/systemd/system/$target"
  run systemctl mask "$target"
done

complete_backup
mark_phase complete "sleep targets masked"
info "息屏、锁屏和挂起策略阶段完成。"
