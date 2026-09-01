#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

ACTION="${1:-apply}"
require_root
load_config false
resolve_real_user
validate_port PROXY_PORT
if [[ -n "${PROXY_HOST:-}" ]]; then
  [[ "$PROXY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || die "PROXY_HOST 不合法：$PROXY_HOST"
fi
if [[ "$ACTION" != "status" ]]; then
  if [[ "$ACTION" == "apply" ]]; then
    start_phase "proxy"
  else
    start_phase "proxy-${ACTION}"
  fi
fi

ENV_BEGIN="# BEGIN vmware-ubuntu-bootstrap proxy"
ENV_END="# END vmware-ubuntu-bootstrap proxy"
PROFILE_FILE="/etc/profile.d/90-vmware-ubuntu-bootstrap-proxy.sh"
APT_FILE="/etc/apt/apt.conf.d/95-vmware-ubuntu-bootstrap-proxy"
SUDOERS_FILE="/etc/sudoers.d/90-vmware-ubuntu-bootstrap-proxy-env"
SYSTEMD_FILE="/etc/systemd/system.conf.d/90-vmware-ubuntu-bootstrap-proxy.conf"
GIT_PROXY_FILE="$VUB_ETC_DIR/git-proxy.conf"
DOCKER_DAEMON_FILE="/etc/systemd/system/docker.service.d/90-vmware-ubuntu-bootstrap-proxy.conf"
DOCKER_PATHS_FILE="$VUB_STATE_DIR/docker-proxy-paths"

proxy_test() {
  local host="$1" port="$2" proxy registry_code github_code
  proxy="http://${host}:${port}"
  registry_code="$(curl -sS -o /dev/null -w '%{http_code}' --proxy "$proxy" \
    --connect-timeout 3 --max-time 10 https://registry-1.docker.io/v2/ 2>/dev/null || true)"
  [[ "$registry_code" == "200" || "$registry_code" == "401" ]] || return 1
  github_code="$(curl -sS -o /dev/null -w '%{http_code}' --proxy "$proxy" \
    --connect-timeout 3 --max-time 10 https://github.com/ 2>/dev/null || true)"
  [[ "$github_code" == "200" || "$github_code" == "301" || "$github_code" == "302" ]]
}

choose_verified_proxy() {
  local iface self_ip cidr host configured_host
  iface="${NETWORK_INTERFACE:-$(current_interface)}"
  self_ip="$(current_ipv4 "$iface")"
  [[ -n "$self_ip" ]] || die "无法确定 Ubuntu IPv4。"
  cidr="${PROXY_SCAN_CIDR:-$(cidr24_for_ip "$self_ip")}"

  configured_host="${VUB_FORCE_PROXY_HOST:-${PROXY_HOST:-}}"
  if [[ -n "$configured_host" ]]; then
    info "验证指定代理 ${configured_host}:${PROXY_PORT} ..." >&2
    proxy_test "$configured_host" "$PROXY_PORT" || die "指定代理不可用：${configured_host}:${PROXY_PORT}"
    printf '%s\n' "$configured_host"
    return 0
  fi

  info "在 $cidr 扫描 TCP $PROXY_PORT ..." >&2
  mapfile -t open_hosts < <(python3 "$SCRIPT_DIR/proxy_scan.py" \
    --cidr "$cidr" --self-ip "$self_ip" --port "$PROXY_PORT")
  local -a verified=()
  for host in "${open_hosts[@]:-}"; do
    [[ -n "$host" ]] || continue
    info "验证 ${host}:${PROXY_PORT} 的 HTTP 代理能力 ..." >&2
    proxy_test "$host" "$PROXY_PORT" && verified+=("$host")
  done

  case "${#verified[@]}" in
    0) die "没有找到可用代理；请检查 Allow LAN、7890 监听和 Windows 防火墙。" ;;
    1) printf '%s\n' "${verified[0]}" ;;
    *)
      warn "发现多个可用代理：${verified[*]}"
      if is_true "$VUB_YES"; then
        die "非交互模式不会替你选择多个代理。"
      fi
      init_input_tty
      host="$(read_default "选择代理 IP" "${verified[0]}")"
      for candidate in "${verified[@]}"; do
        [[ "$host" == "$candidate" ]] && { printf '%s\n' "$host"; return 0; }
      done
      die "选择的 IP 不在已验证列表中。"
      ;;
  esac
}

cpa_host_for_no_proxy() {
  [[ -n "${CPA_BASE_URL:-}" ]] || return 0
  python3 - "$CPA_BASE_URL" "${CPA_BYPASS_PROXY:-false}" <<'PY'
import sys
import ipaddress
from urllib.parse import urlparse
host = urlparse(sys.argv[1]).hostname or ""
force_bypass = sys.argv[2].lower() == "true"
if force_bypass or host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".local"):
    print(host)
else:
    try:
        if ipaddress.ip_address(host).is_private:
            print(host)
    except ValueError:
        pass
PY
}

write_proxy_state() {
  local proxy_url="$1" no_proxy_value="$2" host="$3" port="$4"
  {
    printf 'VUB_PROXY_HOST=%s\n' "$(shell_quote "$host")"
    printf 'VUB_PROXY_PORT=%s\n' "$(shell_quote "$port")"
    printf 'http_proxy=%s\n' "$(shell_quote "$proxy_url")"
    printf 'https_proxy=%s\n' "$(shell_quote "$proxy_url")"
    printf 'HTTP_PROXY=%s\n' "$(shell_quote "$proxy_url")"
    printf 'HTTPS_PROXY=%s\n' "$(shell_quote "$proxy_url")"
    printf 'all_proxy=%s\n' "$(shell_quote "$proxy_url")"
    printf 'ALL_PROXY=%s\n' "$(shell_quote "$proxy_url")"
    printf 'no_proxy=%s\n' "$(shell_quote "$no_proxy_value")"
    printf 'NO_PROXY=%s\n' "$(shell_quote "$no_proxy_value")"
  } | write_managed_file "$VUB_ETC_DIR/proxy.env" 0644 root root
}

git_as_user() {
  runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" git "$@"
}

ensure_git_include() {
  local path="$1"
  if is_dry_run; then
    info "DRY-RUN: add Git include for system, $REAL_USER and root: $path"
    return 0
  fi
  backup_path /etc/gitconfig
  git config --system --fixed-value --get-all include.path "$path" >/dev/null 2>&1 \
    || git config --system --add include.path "$path"
  normalize_system_config_permissions /etc/gitconfig

  backup_path "$REAL_HOME/.gitconfig"
  git_as_user config --global --fixed-value --get-all include.path "$path" >/dev/null 2>&1 \
    || git_as_user config --global --add include.path "$path"

  backup_path /root/.gitconfig
  HOME=/root git config --global --fixed-value --get-all include.path "$path" >/dev/null 2>&1 \
    || HOME=/root git config --global --add include.path "$path"
}

remove_git_include() {
  local path="$1"
  if is_dry_run; then
    info "DRY-RUN: remove Git include for system, $REAL_USER and root: $path"
    return 0
  fi
  if command -v git >/dev/null 2>&1; then
    backup_path /etc/gitconfig
    git config --system --fixed-value --unset-all include.path "$path" 2>/dev/null || true
    normalize_system_config_permissions /etc/gitconfig
    backup_path "$REAL_HOME/.gitconfig"
    git_as_user config --global --fixed-value --unset-all include.path "$path" 2>/dev/null || true
    backup_path /root/.gitconfig
    HOME=/root git config --global --fixed-value --unset-all include.path "$path" 2>/dev/null || true
  fi
}

merge_docker_proxy() {
  local path="$1" proxy_url="$2" no_proxy_value="$3" owner="$4" group="$5"
  local known="false"
  [[ -f "$DOCKER_PATHS_FILE" ]] && grep -Fxq "$path" "$DOCKER_PATHS_FILE" && known="true"
  backup_path "$path"
  if is_dry_run; then
    info "DRY-RUN: merge Docker proxy into $path"
    return 0
  fi
  install -d -m 0700 -o "$owner" -g "$group" "$(dirname "$path")"
  python3 - "$path" "$proxy_url" "$no_proxy_value" "$known" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

path, proxy, no_proxy, known = sys.argv[1:]
target = pathlib.Path(path)
data = {}
if target.exists() and target.stat().st_size:
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"无法解析 Docker JSON {path}: {exc}")
existing = data.get("proxies", {}).get("default")
desired = {"httpProxy": proxy, "httpsProxy": proxy, "noProxy": no_proxy}
if existing and existing != desired and known != "true":
    raise SystemExit(f"{path} 已有非本项目 Docker proxy，拒绝覆盖")
data.setdefault("proxies", {})["default"] = desired
target.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=target.name + ".", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  chown "$owner:$group" "$path"
  chmod 0600 "$path"
  backup_path "$DOCKER_PATHS_FILE"
  grep -Fxq "$path" "$DOCKER_PATHS_FILE" 2>/dev/null || printf '%s\n' "$path" >>"$DOCKER_PATHS_FILE"
  chmod 0600 "$DOCKER_PATHS_FILE"
}

remove_docker_proxy() {
  local path="$1" managed_proxy="$2"
  [[ -f "$path" ]] || return 0
  backup_path "$path"
  if is_dry_run; then
    info "DRY-RUN: remove managed Docker proxy from $path"
    return 0
  fi
  python3 - "$path" "$managed_proxy" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

path, managed_proxy = sys.argv[1:]
target = pathlib.Path(path)
data = json.loads(target.read_text(encoding="utf-8"))
proxies = data.get("proxies")
default = proxies.get("default") if isinstance(proxies, dict) else None
if isinstance(default, dict) and default.get("httpProxy") == managed_proxy and default.get("httpsProxy") == managed_proxy:
    proxies.pop("default", None)
    if not proxies:
        data.pop("proxies", None)
else:
    raise SystemExit(f"{path} 的 proxy 已被外部修改，拒绝自动删除")
fd, tmp = tempfile.mkstemp(prefix=target.name + ".", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

docker_client_proxy_matches() {
  local path="$1" proxy_url="$2" no_proxy_value="$3"
  python3 - "$path" "$proxy_url" "$no_proxy_value" <<'PY'
import json
import pathlib
import sys

path, proxy, no_proxy = sys.argv[1:]
data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
actual = data.get("proxies", {}).get("default", {})
expected = {"httpProxy": proxy, "httpsProxy": proxy, "noProxy": no_proxy}
raise SystemExit(0 if actual == expected else 1)
PY
}

apply_proxy() {
  require_command curl
  require_command python3
  require_command git
  require_command visudo
  [[ -n "${NETWORK_INTERFACE:-}" ]] || NETWORK_INTERFACE="$(current_interface)"
  local host proxy_url lan_cidr no_proxy_value cpa_host sudoers_tmp systemd_tmp apt_tmp
  host="$(choose_verified_proxy)"
  proxy_url="http://${host}:${PROXY_PORT}"
  lan_cidr="${PROXY_SCAN_CIDR:-$(cidr24_for_ip "$(current_ipv4 "$NETWORK_INTERFACE")")}"
  cpa_host="$(cpa_host_for_no_proxy)"
  no_proxy_value="localhost,127.0.0.1,::1,.local,host.docker.internal,gateway.docker.internal,${lan_cidr},${host}"
  [[ -n "$GATEWAY_IPV4" ]] && no_proxy_value+=",${GATEWAY_IPV4}"
  [[ -n "$cpa_host" ]] && no_proxy_value+=",${cpa_host}"

  info "采用代理：$proxy_url"
  write_proxy_state "$proxy_url" "$no_proxy_value" "$host" "$PROXY_PORT"

  {
    printf 'http_proxy="%s"\n' "$proxy_url"
    printf 'https_proxy="%s"\n' "$proxy_url"
    printf 'HTTP_PROXY="%s"\n' "$proxy_url"
    printf 'HTTPS_PROXY="%s"\n' "$proxy_url"
    printf 'all_proxy="%s"\n' "$proxy_url"
    printf 'ALL_PROXY="%s"\n' "$proxy_url"
    printf 'no_proxy="%s"\n' "$no_proxy_value"
    printf 'NO_PROXY="%s"\n' "$no_proxy_value"
  } | replace_marked_block /etc/environment "$ENV_BEGIN" "$ENV_END" 0644

  {
    printf '# Managed by vmware-ubuntu-bootstrap.\n'
    printf 'export http_proxy=%q https_proxy=%q HTTP_PROXY=%q HTTPS_PROXY=%q\n' "$proxy_url" "$proxy_url" "$proxy_url" "$proxy_url"
    printf 'export all_proxy=%q ALL_PROXY=%q\n' "$proxy_url" "$proxy_url"
    printf 'export no_proxy=%q NO_PROXY=%q\n' "$no_proxy_value" "$no_proxy_value"
  } | write_managed_file "$PROFILE_FILE" 0644 root root

  apt_tmp="$(mktemp)"
  render_template "$VUB_PROJECT_DIR/templates/apt-proxy.conf.tpl" "PROXY_URL=$proxy_url" >"$apt_tmp"
  write_managed_file "$APT_FILE" 0644 root root <"$apt_tmp"
  rm -f "$apt_tmp"

  sudoers_tmp="$(mktemp)"
  printf 'Defaults env_keep += "http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY"\n' >"$sudoers_tmp"
  visudo -cf "$sudoers_tmp" >/dev/null
  write_managed_file "$SUDOERS_FILE" 0440 root root <"$sudoers_tmp"
  rm -f "$sudoers_tmp"

  systemd_tmp="$(mktemp)"
  render_template "$VUB_PROJECT_DIR/templates/systemd-proxy.conf.tpl" \
    "PROXY_URL=$proxy_url" "NO_PROXY=$no_proxy_value" >"$systemd_tmp"
  write_managed_file "$SYSTEMD_FILE" 0644 root root <"$systemd_tmp"
  rm -f "$systemd_tmp"

  {
    printf '[http]\n\tproxy = %s\n' "$proxy_url"
    printf '[https]\n\tproxy = %s\n' "$proxy_url"
  } | write_managed_file "$GIT_PROXY_FILE" 0644 root root
  ensure_git_include "$GIT_PROXY_FILE"

  if command -v docker >/dev/null 2>&1 || systemctl list-unit-files --type=service 2>/dev/null | grep -q '^docker\.service'; then
    {
      printf '[Service]\n'
      printf 'Environment="HTTP_PROXY=%s"\n' "$proxy_url"
      printf 'Environment="HTTPS_PROXY=%s"\n' "$proxy_url"
      printf 'Environment="NO_PROXY=%s"\n' "$no_proxy_value"
    } | write_managed_file "$DOCKER_DAEMON_FILE" 0644 root root
    merge_docker_proxy /root/.docker/config.json "$proxy_url" "$no_proxy_value" root root
    merge_docker_proxy "$REAL_HOME/.docker/config.json" "$proxy_url" "$no_proxy_value" "$REAL_USER" "$REAL_GROUP"
  fi

  if command -v snap >/dev/null 2>&1; then
    if [[ ! -f "$VUB_STATE_DIR/snap-proxy.previous" ]] && ! is_dry_run; then
      backup_path "$VUB_STATE_DIR/snap-proxy.previous"
      {
        printf 'previous_http=%q\n' "$(snap get system proxy.http 2>/dev/null || true)"
        printf 'previous_https=%q\n' "$(snap get system proxy.https 2>/dev/null || true)"
      } >"$VUB_STATE_DIR/snap-proxy.previous"
      chmod 0600 "$VUB_STATE_DIR/snap-proxy.previous"
    fi
    run snap set system proxy.http="$proxy_url" proxy.https="$proxy_url"
  fi

  if ! is_dry_run; then
    systemctl daemon-reexec
    systemctl daemon-reload
    if systemctl is-active --quiet docker 2>/dev/null; then
      systemctl restart docker
    fi
  fi

  if is_dry_run; then
    complete_backup
    mark_phase planned "proxy=$proxy_url"
    info "DRY-RUN: 代理配置计划完成。"
    return 0
  fi

  load_proxy_state
  proxy_test "$host" "$PROXY_PORT" || die "持久化后代理复验失败。"
  [[ "$(git config --get http.proxy || true)" == "$proxy_url" ]] || die "系统 Git 代理复验失败。"
  [[ "$(git_as_user config --get http.proxy || true)" == "$proxy_url" ]] || die "用户 Git 代理复验失败。"
  [[ "$(HOME=/root git config --get http.proxy || true)" == "$proxy_url" ]] || die "root Git 代理复验失败。"
  apt-config dump 2>/dev/null | grep -Fq "${proxy_url}/" || die "APT 代理复验失败。"
  systemctl show-environment 2>/dev/null | grep -Fxq "HTTP_PROXY=$proxy_url" \
    || die "systemd manager 代理复验失败。"
  if command -v docker >/dev/null 2>&1 || systemctl list-unit-files --type=service 2>/dev/null | grep -q '^docker\.service'; then
    DOCKER_ENVIRONMENT="$(systemctl show docker --property=Environment --value 2>/dev/null || true)"
    grep -Fq "HTTP_PROXY=$proxy_url" <<<"$DOCKER_ENVIRONMENT" \
      || die "Docker daemon HTTP 代理复验失败。"
    grep -Fq "HTTPS_PROXY=$proxy_url" <<<"$DOCKER_ENVIRONMENT" \
      || die "Docker daemon HTTPS 代理复验失败。"
    grep -Fq "NO_PROXY=$no_proxy_value" <<<"$DOCKER_ENVIRONMENT" \
      || die "Docker daemon NO_PROXY 复验失败。"
    docker_client_proxy_matches /root/.docker/config.json "$proxy_url" "$no_proxy_value" \
      || die "root Docker client 代理复验失败。"
    docker_client_proxy_matches "$REAL_HOME/.docker/config.json" "$proxy_url" "$no_proxy_value" \
      || die "用户 Docker client 代理复验失败。"
  fi

  complete_backup
  mark_phase complete "proxy=$proxy_url"
  info "代理配置完成。重新登录后所有登录环境生效。"
}

show_status() {
  echo "=== Managed proxy state ==="
  if load_proxy_state; then
    echo "proxy:    ${http_proxy:-未配置}"
    echo "all_proxy: ${all_proxy:-未配置}"
    echo "no_proxy: ${no_proxy:-未配置}"
  else
    echo "(未配置)"
  fi
  echo
  echo "=== APT ==="
  cat "$APT_FILE" 2>/dev/null || echo "(未配置)"
  echo
  echo "=== Git (system / $REAL_USER / root) ==="
  command -v git >/dev/null 2>&1 || { echo "Git 未安装"; return 0; }
  echo "system/effective: $(GIT_CONFIG_GLOBAL=/dev/null HOME=/root git config --get http.proxy 2>/dev/null || echo 未配置)"
  echo "user/effective:   $(git_as_user config --get http.proxy 2>/dev/null || echo 未配置)"
  echo "root/effective:   $(HOME=/root git config --get http.proxy 2>/dev/null || echo 未配置)"
  echo
  echo "=== systemd / Docker ==="
  systemctl show-environment 2>/dev/null | grep -Ei '^(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || echo "systemd manager: 未配置或尚未重载"
  systemctl show docker -p Environment 2>/dev/null || true
}

disable_proxy() {
  local managed_proxy=""
  local docker_cleanup_ok="true"
  if load_proxy_state; then
    managed_proxy="${http_proxy:-}"
  fi

  if grep -Fxq "$ENV_BEGIN" /etc/environment 2>/dev/null; then
    remove_marked_block /etc/environment "$ENV_BEGIN" "$ENV_END" 0644
  fi
  remove_managed_path "$PROFILE_FILE"
  remove_managed_path "$APT_FILE"
  remove_managed_path "$SUDOERS_FILE"
  remove_managed_path "$SYSTEMD_FILE"
  remove_git_include "$GIT_PROXY_FILE"
  remove_managed_path "$GIT_PROXY_FILE"
  remove_managed_path "$DOCKER_DAEMON_FILE"

  if [[ -n "$managed_proxy" && -f "$DOCKER_PATHS_FILE" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      if ! remove_docker_proxy "$path" "$managed_proxy"; then
        docker_cleanup_ok="false"
        warn "Docker 客户端配置未自动清理：$path"
      fi
    done <"$DOCKER_PATHS_FILE"
    if is_true "$docker_cleanup_ok"; then
      remove_managed_path "$DOCKER_PATHS_FILE"
    fi
  fi

  if command -v snap >/dev/null 2>&1; then
    if [[ -r "$VUB_STATE_DIR/snap-proxy.previous" ]]; then
      # shellcheck disable=SC1090
      source "$VUB_STATE_DIR/snap-proxy.previous"
      if [[ -n "${previous_http:-}" && "$previous_http" != "null" ]]; then
        run snap set system proxy.http="$previous_http"
      else
        run snap unset system proxy.http || true
      fi
      if [[ -n "${previous_https:-}" && "$previous_https" != "null" ]]; then
        run snap set system proxy.https="$previous_https"
      else
        run snap unset system proxy.https || true
      fi
    else
      warn "没有 Snap 旧值记录，未改动 Snap proxy。"
    fi
    [[ -f "$VUB_STATE_DIR/snap-proxy.previous" ]] && remove_managed_path "$VUB_STATE_DIR/snap-proxy.previous"
  fi

  remove_managed_path "$VUB_ETC_DIR/proxy.env"
  if ! is_dry_run; then
    systemctl unset-environment HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy 2>/dev/null || true
    systemctl daemon-reexec
    systemctl daemon-reload
    if systemctl is-active --quiet docker 2>/dev/null; then
      systemctl restart docker || true
    fi
  fi
  complete_backup
  mark_phase complete "proxy disabled"
  info "本项目管理的代理配置已移除。"
}

case "$ACTION" in
  apply) apply_proxy ;;
  status) show_status ;;
  off) disable_proxy ;;
  *) die "未知 proxy 操作：$ACTION" ;;
esac
