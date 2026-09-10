#!/usr/bin/env bash
# Per-user GNOME settings are independent of login-shell proxy environment.

desktop_proxy_keys() {
  cat <<'EOF'
org.gnome.system.proxy.http host
org.gnome.system.proxy.http port
org.gnome.system.proxy.http enabled
org.gnome.system.proxy.http use-authentication
org.gnome.system.proxy.https host
org.gnome.system.proxy.https port
org.gnome.system.proxy ignore-hosts
org.gnome.system.proxy mode
EOF
}

desktop_proxy_available() {
  [[ -n "${REAL_UID:-}" && -S "/run/user/$REAL_UID/bus" ]] \
    && command -v gsettings >/dev/null 2>&1
}

desktop_proxy_settings() {
  # Reads must stay read-only even during --dry-run; writes are gated below.
  runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" gsettings "$@"
}

desktop_proxy_snapshot() {
  local schema key value
  while read -r schema key; do
    value=$(desktop_proxy_settings get "$schema" "$key") || return 1
    printf '%s\t%s\t%s\n' "$schema" "$key" "$value"
  done < <(desktop_proxy_keys)
}

desktop_proxy_restore() {
  local path="$1" schema key value
  while IFS=$'\t' read -r schema key value; do
    # Only restore the known keys; never execute a snapshot as shell code.
    desktop_proxy_keys | grep -Fxq "$schema $key" || die "桌面代理备份包含未知配置键。"
    desktop_proxy_settings set "$schema" "$key" "$value" || return 1
  done <"$path"
}

desktop_proxy_begin_change() {
  init_backup_dir
  if [[ ! -e "$VUB_BACKUP_DIR/desktop-proxy.before.tsv" ]]; then
    desktop_proxy_snapshot >"$VUB_BACKUP_DIR/desktop-proxy.before.tsv" || return 1
    chmod 0600 "$VUB_BACKUP_DIR/desktop-proxy.before.tsv"
    printf '%s\n' "$REAL_UID" >"$VUB_BACKUP_DIR/desktop-proxy.uid"
  fi
}

desktop_proxy_apply() {
  local host="$1" port="$2" bypass="$3" schema key ignored previous managed desired
  if ! desktop_proxy_available; then
    warn "没有可用的 GNOME 用户会话；桌面代理未更新，请登录 Ubuntu 桌面后重跑刷新脚本。"
    return 0
  fi
  while read -r schema key; do
    [[ "$(desktop_proxy_settings writable "$schema" "$key")" == true ]] \
      || die "桌面代理设置不可写：$schema $key。"
  done < <(desktop_proxy_keys)
  if is_dry_run; then
    info "DRY-RUN: 将为 $REAL_USER 更新 GNOME HTTP/HTTPS 代理为 $host:$port。"
    return 0
  fi
  ignored=$(python3 - "$bypass" <<'PY'
import json, sys
print(json.dumps([('*' + x if x.startswith('.') else x)
                  for x in sys.argv[1].split(',') if x]))
PY
  )
  desired=$(mktemp)
  {
    printf "org.gnome.system.proxy.http\thost\t'%s'\n" "$host"
    printf 'org.gnome.system.proxy.http\tport\t%s\n' "$port"
    printf 'org.gnome.system.proxy.http\tenabled\ttrue\n'
    printf 'org.gnome.system.proxy.http\tuse-authentication\tfalse\n'
    printf "org.gnome.system.proxy.https\thost\t'%s'\n" "$host"
    printf 'org.gnome.system.proxy.https\tport\t%s\n' "$port"
    printf 'org.gnome.system.proxy\tignore-hosts\t%s\n' "$ignored"
    # Enable manual mode last so the new endpoints are already in place.
    printf "org.gnome.system.proxy\tmode\t'manual'\n"
  } >"$desired"
  previous="$VUB_STATE_DIR/desktop-proxy-$REAL_UID.previous.tsv"
  managed="$VUB_STATE_DIR/desktop-proxy-$REAL_UID.managed.tsv"
  desktop_proxy_begin_change || { rm -f "$desired"; die "无法备份当前桌面代理。"; }
  if [[ ! -e "$previous" ]]; then
    write_managed_file "$previous" 0600 root root <"$VUB_BACKUP_DIR/desktop-proxy.before.tsv"
  fi
  if ! desktop_proxy_restore "$desired"; then
    rm -f "$desired"
    die "桌面代理写入失败。"
  fi
  rm -f "$desired"
  # Save canonical GVariant formatting for verification and safe removal later.
  desktop_proxy_snapshot | write_managed_file "$managed" 0600 root root
  [[ "$(desktop_proxy_settings get org.gnome.system.proxy mode)" == "'manual'" \
    && "$(desktop_proxy_settings get org.gnome.system.proxy.http host)" == "'$host'" \
    && "$(desktop_proxy_settings get org.gnome.system.proxy.http port)" == "$port" \
    && "$(desktop_proxy_settings get org.gnome.system.proxy.https host)" == "'$host'" \
    && "$(desktop_proxy_settings get org.gnome.system.proxy.https port)" == "$port" ]] \
    || die "GNOME 桌面代理复验失败。"
  info "GNOME 桌面代理已更新：$host:$port；Firefox 等浏览器请选择使用系统代理。"
}

desktop_proxy_disable() {
  local previous="$VUB_STATE_DIR/desktop-proxy-$REAL_UID.previous.tsv"
  local managed="$VUB_STATE_DIR/desktop-proxy-$REAL_UID.managed.tsv" current
  [[ -f "$previous" && -f "$managed" ]] || return 0
  desktop_proxy_available || die "请登录 $REAL_USER 的 Ubuntu 桌面后再关闭桌面代理。"
  if is_dry_run; then
    info "DRY-RUN: 将恢复 $REAL_USER 原来的 GNOME 桌面代理。"
    return 0
  fi
  current=$(desktop_proxy_snapshot) || return 1
  if [[ "$current" != "$(cat "$managed")" ]]; then
    warn "桌面代理已被外部修改，保留用户当前设置及原始备份。"
    return 0
  fi
  desktop_proxy_begin_change || return 1
  desktop_proxy_restore "$previous" || die "无法恢复原桌面代理。"
  remove_managed_path "$previous"
  remove_managed_path "$managed"
}

desktop_proxy_rollback() {
  local source_backup="$1"
  [[ -f "$source_backup/desktop-proxy.before.tsv" ]] || return 0
  [[ "$(cat "$source_backup/desktop-proxy.uid")" == "$REAL_UID" ]] \
    || die "桌面代理备份属于其他用户，拒绝写入当前用户。"
  desktop_proxy_available || die "请登录 $REAL_USER 的桌面后再次回滚，以恢复桌面代理。"
  if is_dry_run; then
    info "DRY-RUN: 将恢复备份中的 GNOME 桌面代理。"
    return 0
  fi
  desktop_proxy_begin_change || return 1
  desktop_proxy_restore "$source_backup/desktop-proxy.before.tsv" \
    || die "桌面代理回滚失败。"
}
