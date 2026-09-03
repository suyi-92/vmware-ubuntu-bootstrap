#!/usr/bin/env bash
set -Eeuo pipefail
# Keep the final function in content pipelines in the current shell where possible.
shopt -s lastpipe

VUB_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VUB_PROJECT_DIR="${VUB_PROJECT_DIR:-$(cd -- "$VUB_SCRIPT_DIR/.." && pwd -P)}"
VUB_CONFIG_FILE="${VUB_CONFIG_FILE:-$VUB_PROJECT_DIR/config.env}"
VUB_DRY_RUN="${VUB_DRY_RUN:-false}"
VUB_YES="${VUB_YES:-false}"
VUB_VERBOSE="${VUB_VERBOSE:-false}"
VUB_TESTING="${VUB_TESTING:-false}"

VUB_ETC_DIR="${VUB_ETC_DIR:-/etc/vmware-ubuntu-bootstrap}"
VUB_STATE_DIR="${VUB_STATE_DIR:-/var/lib/vmware-ubuntu-bootstrap}"
VUB_LOG_DIR="${VUB_LOG_DIR:-/var/log/vmware-ubuntu-bootstrap}"
VUB_BACKUP_ROOT="${VUB_BACKUP_ROOT:-/var/backups/vmware-ubuntu-bootstrap}"
VUB_PHASE_NAME="${VUB_PHASE_NAME:-unknown}"
VUB_LOG_FILE="${VUB_LOG_FILE:-}"
VUB_BACKUP_DIR="${VUB_BACKUP_DIR:-}"
VUB_INPUT_TTY="${VUB_INPUT_TTY:-}"

TARGET_USER="${TARGET_USER:-}"
REAL_USER="${REAL_USER:-}"
REAL_HOME="${REAL_HOME:-}"
REAL_UID="${REAL_UID:-}"
REAL_GID="${REAL_GID:-}"
REAL_GROUP="${REAL_GROUP:-}"

if [[ -t 1 ]]; then
  VUB_RED=$'\033[31m'
  VUB_YELLOW=$'\033[33m'
  VUB_GREEN=$'\033[32m'
  VUB_BLUE=$'\033[34m'
  VUB_CYAN=$'\033[36m'
  VUB_DIM=$'\033[2m'
  VUB_BOLD=$'\033[1m'
  VUB_RESET=$'\033[0m'
else
  VUB_RED=""
  VUB_YELLOW=""
  VUB_GREEN=""
  VUB_BLUE=""
  VUB_CYAN=""
  VUB_DIM=""
  VUB_BOLD=""
  VUB_RESET=""
fi
export VUB_RED VUB_YELLOW VUB_GREEN VUB_BLUE VUB_CYAN VUB_DIM VUB_BOLD VUB_RESET

export VUB_PROJECT_DIR VUB_CONFIG_FILE VUB_DRY_RUN VUB_YES VUB_VERBOSE VUB_TESTING
export VUB_ETC_DIR VUB_STATE_DIR VUB_LOG_DIR VUB_BACKUP_ROOT VUB_PHASE_NAME

_vub_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

_vub_log() {
  local level="$1"
  shift
  local line
  line="[$(_vub_timestamp)] [$level] $*"
  printf '%s\n' "$line"
  if [[ -n "$VUB_LOG_FILE" && -d "$(dirname "$VUB_LOG_FILE")" ]]; then
    printf '%s\n' "$line" >>"$VUB_LOG_FILE" 2>/dev/null || true
  fi
}

info() {
  printf '%b' "$VUB_GREEN"
  _vub_log INFO "$*"
  printf '%b' "$VUB_RESET"
}

warn() {
  printf '%b' "$VUB_YELLOW" >&2
  _vub_log WARN "$*" >&2
  printf '%b' "$VUB_RESET" >&2
}

die() {
  printf '%b' "$VUB_RED" >&2
  _vub_log ERROR "$*" >&2
  printf '%b' "$VUB_RESET" >&2
  exit 1
}

is_true() {
  case "${1:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

is_dry_run() {
  is_true "$VUB_DRY_RUN"
}

shell_join() {
  local out="" arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+="${out:+ }${arg}"
  done
  printf '%s\n' "$out"
}

run() {
  if is_dry_run; then
    info "DRY-RUN: $(shell_join "$@")"
    return 0
  fi
  if is_true "$VUB_VERBOSE"; then
    info "RUN: $(shell_join "$@")"
  fi
  "$@"
}

run_logged() {
  local description="$1"
  shift
  if is_dry_run; then
    info "DRY-RUN: $description: $(shell_join "$@")"
    return 0
  fi
  local tmp code
  tmp="$(mktemp)"
  set +e
  if is_true "$VUB_VERBOSE"; then
    "$@" 2>&1 | tee "$tmp"
    code="${PIPESTATUS[0]}"
  else
    "$@" >"$tmp" 2>&1
    code="$?"
  fi
  set -e
  if [[ -n "$VUB_LOG_FILE" ]]; then
    sed -E 's/(Authorization:[[:space:]]*Bearer)[[:space:]]+[^[:space:]]+/\1 <redacted>/Ig' "$tmp" >>"$VUB_LOG_FILE" 2>/dev/null || true
  fi
  if (( code != 0 )); then
    warn "$description 失败，诊断尾部如下："
    tail -n 60 "$tmp" >&2 || true
    rm -f "$tmp"
    return "$code"
  fi
  rm -f "$tmp"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 sudo 运行。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

make_private_temp_file() {
  local template="$1"
  (
    umask 077
    mktemp "$template"
  )
}

normalize_system_config_permissions() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ -f "$path" ]] || die "系统配置不是普通文件：$path"
  chown root:root -- "$path"
  chmod 0644 -- "$path"
}

install_missing_apt_packages() {
  local description="$1" package
  shift
  local -a missing=()

  require_command apt-get
  require_command dpkg-query
  for package in "$@"; do
    if ! dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -Eq '(^|[[:space:]])ok installed$'; then
      missing+=("$package")
    fi
  done

  VUB_LAST_MISSING_PACKAGE_COUNT="${#missing[@]}"
  if (( VUB_LAST_MISSING_PACKAGE_COUNT == 0 )); then
    info "$description：全部已安装，跳过 APT。"
    return 0
  fi

  info "$description：发现 $VUB_LAST_MISSING_PACKAGE_COUNT 个缺失包：${missing[*]}"
  run_logged "APT 更新索引" env DEBIAN_FRONTEND=noninteractive apt-get update
  run_logged "$description" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${missing[@]}"
}

upgrade_installed_apt_packages() {
  require_command apt-get
  run_logged "升级当前已安装的 APT 软件包" \
    env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs
}

install_or_upgrade_apt_packages() {
  local description="$1"
  shift
  (( $# > 0 )) || die "$description 没有收到软件包列表。"
  require_command apt-get
  run_logged "$description" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "$@"
}

verify_docker_runtime() {
  if is_dry_run; then
    info "DRY-RUN: verify docker.socket, docker.service and docker info"
    return 0
  fi

  require_command systemctl
  require_command docker
  if ! systemctl is-enabled --quiet docker.socket; then
    die "Docker socket 未设为开机启用。"
  fi
  if ! systemctl is-active --quiet docker.socket; then
    die "Docker socket 未运行。"
  fi
  if ! systemctl is-enabled --quiet docker.service; then
    die "Docker service 未设为开机启用。"
  fi
  if ! systemctl is-active --quiet docker.service; then
    die "Docker service 未运行。"
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon 无法响应 docker info。"
  fi
}

activate_docker_runtime() {
  if ! is_dry_run; then
    require_command systemctl
    require_command docker
  fi

  if ! run systemctl daemon-reload; then
    die "systemd 重新加载失败，无法启动 Docker。"
  fi
  if ! run systemctl reset-failed docker.service docker.socket; then
    die "无法清除 Docker service/socket 的失败状态。"
  fi
  if ! run systemctl enable docker.socket docker.service; then
    die "无法将 Docker service/socket 设为开机启用。"
  fi
  if ! run systemctl start docker.socket; then
    die "Docker socket 启动失败。"
  fi
  if ! run systemctl restart docker.service; then
    die "Docker service 启动失败；请查看 journalctl -xeu docker.service。"
  fi

  verify_docker_runtime
}

validate_sudoers_username() {
  local username="$1"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

render_passwordless_sudoers() {
  local username="$1"
  validate_sudoers_username "$username" \
    || die "无法为不安全的用户名生成 sudoers 规则：$username"
  printf '# Managed by vmware-ubuntu-bootstrap.\n'
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username"
}

resolve_real_user() {
  local candidate="${TARGET_USER:-}"
  if [[ -z "$candidate" || "$candidate" == "root" ]]; then
    candidate="${SUDO_USER:-}"
  fi
  if [[ -z "$candidate" || "$candidate" == "root" ]]; then
    candidate="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "$candidate" || "$candidate" == "root" ]]; then
    candidate="$(getent passwd 2>/dev/null | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1; exit}')"
  fi
  [[ -n "$candidate" && "$candidate" != "root" ]] || die "无法确定要配置的普通用户，请设置 TARGET_USER。"

  local entry
  entry="$(getent passwd "$candidate" || true)"
  [[ -n "$entry" ]] || die "用户不存在：$candidate"
  IFS=: read -r REAL_USER _ REAL_UID REAL_GID _ REAL_HOME _ <<<"$entry"
  REAL_GROUP="$(getent group "$REAL_GID" | cut -d: -f1)"
  [[ -n "$REAL_HOME" && "$REAL_HOME" == /* ]] || die "用户 home 不合法：$REAL_HOME"
  TARGET_USER="$REAL_USER"
  export TARGET_USER REAL_USER REAL_HOME REAL_UID REAL_GID REAL_GROUP
}

run_as_user() {
  [[ -n "$REAL_USER" ]] || resolve_real_user
  if is_dry_run; then
    info "DRY-RUN as $REAL_USER: $(shell_join "$@")"
    return 0
  fi
  runuser -u "$REAL_USER" -- env \
    HOME="$REAL_HOME" USER="$REAL_USER" LOGNAME="$REAL_USER" \
    PATH="$REAL_HOME/.local/bin:$REAL_HOME/.codex/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

run_as_user_with_bus() {
  [[ -n "$REAL_USER" ]] || resolve_real_user
  local bus="unix:path=/run/user/${REAL_UID}/bus"
  if [[ ! -S "/run/user/${REAL_UID}/bus" ]]; then
    return 2
  fi
  if is_dry_run; then
    info "DRY-RUN desktop as $REAL_USER: $(shell_join "$@")"
    return 0
  fi
  runuser -u "$REAL_USER" -- env \
    HOME="$REAL_HOME" USER="$REAL_USER" LOGNAME="$REAL_USER" \
    DBUS_SESSION_BUS_ADDRESS="$bus" \
    "$@"
}

init_input_tty() {
  if [[ -n "$VUB_INPUT_TTY" ]]; then
    [[ -r "$VUB_INPUT_TTY" ]] || die "无法读取交互终端：$VUB_INPUT_TTY"
  elif [[ -r /dev/tty ]]; then
    VUB_INPUT_TTY="/dev/tty"
  elif [[ -t 0 ]]; then
    VUB_INPUT_TTY="/dev/stdin"
  else
    die "需要交互式终端；自动模式请提供 --config。"
  fi
  export VUB_INPUT_TTY
}

read_default() {
  local prompt="$1" default_value="${2:-}" value=""
  [[ -n "$VUB_INPUT_TTY" ]] || init_input_tty
  if [[ "$VUB_INPUT_TTY" == "/dev/tty" ]]; then
    if [[ -n "$default_value" ]]; then
      IFS= read -e -i "$default_value" -r -p "${prompt}：" value <"$VUB_INPUT_TTY" || true
    else
      IFS= read -e -r -p "${prompt}：" value <"$VUB_INPUT_TTY" || true
    fi
  else
    printf '%b' "${VUB_BOLD}${prompt}${VUB_RESET}：" >"$VUB_INPUT_TTY"
    IFS= read -r value <"$VUB_INPUT_TTY" || true
  fi
  printf '%s\n' "${value:-$default_value}"
}

read_secret() {
  local prompt="$1" has_existing="${2:-false}" value="" character="" tty_state=""
  [[ -n "$VUB_INPUT_TTY" ]] || init_input_tty
  if [[ "$VUB_INPUT_TTY" == "/dev/tty" ]]; then
    tty_state="$(stty -g <"$VUB_INPUT_TTY")" || die "无法读取终端状态。"
    stty -echo <"$VUB_INPUT_TTY" || die "无法关闭敏感输入回显。"
    trap 'stty "$tty_state" <"$VUB_INPUT_TTY" 2>/dev/null || true; exit 130' HUP INT TERM
    if is_true "$has_existing"; then
      printf '%b' "${VUB_BOLD}${prompt}${VUB_RESET}（已配置，直接回车保留）：" >"$VUB_INPUT_TTY"
    else
      printf '%b' "${VUB_BOLD}${prompt}${VUB_RESET}：" >"$VUB_INPUT_TTY"
    fi
    while IFS= read -r -n 1 character <"$VUB_INPUT_TTY"; do
      [[ -n "$character" ]] || break
      case "$character" in
        $'\177'|$'\b')
          if [[ -n "$value" ]]; then
            value="${value%?}"
            printf '\b \b' >"$VUB_INPUT_TTY"
          fi
          ;;
        $'\025')
          while [[ -n "$value" ]]; do
            value="${value%?}"
            printf '\b \b' >"$VUB_INPUT_TTY"
          done
          ;;
        *)
          value+="$character"
          printf '*' >"$VUB_INPUT_TTY"
          ;;
      esac
    done
    stty "$tty_state" <"$VUB_INPUT_TTY" 2>/dev/null || true
    trap - HUP INT TERM
  else
    if is_true "$has_existing"; then
      printf '%b' "${VUB_BOLD}${prompt}${VUB_RESET}（已配置，直接回车保留）：" >"$VUB_INPUT_TTY"
    else
      printf '%b' "${VUB_BOLD}${prompt}${VUB_RESET}：" >"$VUB_INPUT_TTY"
    fi
    stty -echo <"$VUB_INPUT_TTY" 2>/dev/null || true
    IFS= read -r value <"$VUB_INPUT_TTY" || true
    stty echo <"$VUB_INPUT_TTY" 2>/dev/null || true
  fi
  printf '\n' >"$VUB_INPUT_TTY"
  printf '%s\n' "$value"
}

read_yes_no() {
  local prompt="$1" default_value="${2:-yes}" value default_input
  case "${default_value,,}" in
    y|yes|true|1) default_value="yes"; default_input="Y" ;;
    n|no|false|0) default_value="no"; default_input="N" ;;
    *) die "read_yes_no 默认值必须是 yes 或 no。" ;;
  esac
  [[ -n "$VUB_INPUT_TTY" ]] || init_input_tty
  while true; do
    if [[ "$VUB_INPUT_TTY" == "/dev/tty" ]]; then
      IFS= read -e -i "$default_input" -r -p "${prompt}：" value <"$VUB_INPUT_TTY" || true
    else
      printf '%b' "${VUB_BOLD}${prompt}${VUB_RESET}：" >"$VUB_INPUT_TTY"
      IFS= read -r value <"$VUB_INPUT_TTY" || true
    fi
    if [[ -z "$value" ]]; then
      [[ "$default_value" == "yes" ]]
      return
    fi
    case "${value,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "请输入 yes 或 no。" ;;
    esac
  done
}

shell_quote() {
  printf '%q' "$1"
}

apply_config_defaults() {
  : "${VUB_CONFIG_VERSION:=1}"
  : "${TARGET_USER:=}"
  : "${NETWORK_INTERFACE:=}"
  : "${PROXY_HOST:=}"
  : "${PROXY_PORT:=7890}"
  : "${PROXY_SCAN_CIDR:=}"
  : "${CONFIGURE_STATIC_NETWORK:=true}"
  : "${STATIC_IPV4_PREFIX:=192.168.1}"
  : "${STATIC_IPV4_LAST_OCTET:=254}"
  : "${PREFIX_LENGTH:=24}"
  : "${GATEWAY_IPV4:=}"
  : "${DNS_SERVERS:=}"
  : "${HOSTNAME:=}"
  : "${TIMEZONE:=America/New_York}"
  : "${SSH_PORT:=22}"
  : "${ADMIN_PUBKEYS:=}"
  : "${ENABLE_UFW:=false}"
  : "${DISABLE_SSH_PASSWORD:=false}"
  : "${CONFIRM_SSH_KEY_LOGIN:=false}"
  : "${CONFIGURE_CODEX:=true}"
  : "${CPA_BASE_URL:=}"
  : "${CPA_MODEL_ID:=}"
  : "${CPA_BYPASS_PROXY:=false}"
  : "${RUN_CPA_SMOKE:=true}"
  : "${RUN_CODEX_SMOKE:=true}"
  : "${ENABLE_UPSTREAM_APT_SOURCES:=true}"
  : "${UPGRADE_INSTALLED_PACKAGES:=true}"
  : "${INSTALL_DOCKER:=true}"
  : "${CONFIGURE_FCITX5_RIME:=true}"
  : "${ENABLE_PASSWORDLESS_SUDO:=true}"
}

load_config() {
  local required="${1:-true}"
  if [[ -f "$VUB_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$VUB_CONFIG_FILE"
  elif is_true "$required"; then
    die "找不到配置文件：$VUB_CONFIG_FILE"
  fi
  apply_config_defaults
}

validate_bool() {
  local name="$1" value="${!1:-}"
  [[ "$value" == "true" || "$value" == "false" ]] || die "$name 必须是 true 或 false，当前：$value"
}

validate_port() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是数字端口，当前：$value"
  (( value >= 1 && value <= 65535 )) || die "$name 超出范围 1–65535：$value"
}

validate_hostname_value() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  [[ ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "HOSTNAME 不合法：$value"
}

validate_cpa_url() {
  local value="$1"
  [[ -n "$value" ]] || die "CPA_BASE_URL 不能为空。"
  python3 - "$value" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

value = sys.argv[1].rstrip("/")
parsed = urlparse(value)
if parsed.scheme not in {"http", "https"} or not parsed.hostname:
    raise SystemExit("CPA_BASE_URL 必须是 http(s) URL")
if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path != "/v1":
    raise SystemExit("CPA_BASE_URL 必须精确指向 /v1，且不能带 query/fragment")
if any(ord(char) < 32 or char in {'"', "'", "\\"} for char in value):
    raise SystemExit("CPA_BASE_URL 包含不安全字符")
if parsed.scheme == "http":
    host = parsed.hostname
    allowed = host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".local")
    try:
        allowed = allowed or ipaddress.ip_address(host).is_private
    except ValueError:
        pass
    if not allowed:
        raise SystemExit("公网 CPA 地址必须使用 HTTPS")
print(value)
PY
}

validate_config() {
  apply_config_defaults
  [[ "$VUB_CONFIG_VERSION" =~ ^[0-9]+$ ]] || die "VUB_CONFIG_VERSION 必须是数字。"
  validate_port PROXY_PORT
  validate_port SSH_PORT
  validate_bool CONFIGURE_STATIC_NETWORK
  validate_bool ENABLE_UFW
  validate_bool DISABLE_SSH_PASSWORD
  validate_bool CONFIRM_SSH_KEY_LOGIN
  validate_bool CONFIGURE_CODEX
  validate_bool CPA_BYPASS_PROXY
  validate_bool RUN_CPA_SMOKE
  validate_bool RUN_CODEX_SMOKE
  validate_bool ENABLE_UPSTREAM_APT_SOURCES
  validate_bool UPGRADE_INSTALLED_PACKAGES
  validate_bool INSTALL_DOCKER
  validate_bool CONFIGURE_FCITX5_RIME
  validate_bool ENABLE_PASSWORDLESS_SUDO
  [[ "$STATIC_IPV4_PREFIX" == "192.168.1" ]] || die "首版 STATIC_IPV4_PREFIX 必须为 192.168.1。"
  [[ "$STATIC_IPV4_LAST_OCTET" =~ ^[0-9]+$ ]] || die "静态 IP 末位必须是数字。"
  (( STATIC_IPV4_LAST_OCTET >= 2 && STATIC_IPV4_LAST_OCTET <= 254 )) \
    || die "静态 IP 末位只能是 2–254；255 是广播地址。"
  [[ "$PREFIX_LENGTH" == "24" ]] || die "首版 PREFIX_LENGTH 必须为 24。"
  [[ -z "$NETWORK_INTERFACE" || "$NETWORK_INTERFACE" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || die "NETWORK_INTERFACE 不合法：$NETWORK_INTERFACE"
  if [[ -n "$PROXY_HOST" ]]; then
    [[ "$PROXY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
      || die "PROXY_HOST 不合法：$PROXY_HOST"
  fi
  if [[ -n "$PROXY_SCAN_CIDR" ]]; then
    python3 - "$PROXY_SCAN_CIDR" <<'PY' >/dev/null
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
if network.version != 4 or network.num_addresses > 256:
    raise SystemExit("PROXY_SCAN_CIDR 必须是 IPv4 /24 或更小网段")
PY
  fi
  validate_hostname_value "$HOSTNAME"
  if is_true "$DISABLE_SSH_PASSWORD" && ! is_true "$CONFIRM_SSH_KEY_LOGIN"; then
    die "关闭 SSH 密码前必须设置 CONFIRM_SSH_KEY_LOGIN=true。"
  fi
  if is_true "$CONFIGURE_CODEX"; then
    validate_cpa_url "$CPA_BASE_URL" >/dev/null
    [[ -n "$CPA_MODEL_ID" && "$CPA_MODEL_ID" =~ ^[A-Za-z0-9._:/-]+$ ]] \
      || die "CPA_MODEL_ID 不能为空，且只能包含英文、数字、点、下划线、冒号、斜杠和短横线。"
  fi
}

current_interface() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}'
}

current_ipv4() {
  local iface="${1:-$(current_interface)}"
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

current_gateway() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}'
}

current_dns_servers() {
  local iface="${1:-$(current_interface)}" result=""
  if command -v resolvectl >/dev/null 2>&1; then
    result="$(resolvectl dns "$iface" 2>/dev/null | sed -E 's/^.*:[[:space:]]*//' | tr '\n' ' ' | xargs || true)"
  fi
  if [[ -z "$result" && -r /etc/resolv.conf ]]; then
    result="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf | tr '\n' ' ' | xargs || true)"
  fi
  printf '%s\n' "$result"
}

cidr24_for_ip() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_network(f"{sys.argv[1]}/24", strict=False))
PY
}

init_runtime_dirs() {
  if is_dry_run; then
    info "DRY-RUN: create runtime directories under $VUB_ETC_DIR, $VUB_STATE_DIR, $VUB_LOG_DIR, $VUB_BACKUP_ROOT"
    return 0
  fi
  install -d -m 0755 -o root -g root "$VUB_ETC_DIR" "$VUB_STATE_DIR"
  install -d -m 0700 -o root -g root "$VUB_LOG_DIR" "$VUB_BACKUP_ROOT"
}

start_phase() {
  VUB_PHASE_NAME="$1"
  export VUB_PHASE_NAME
  init_runtime_dirs
  VUB_LOG_FILE="$VUB_LOG_DIR/${VUB_PHASE_NAME}-$(date '+%Y%m%d-%H%M%S').log"
  export VUB_LOG_FILE
  if ! is_dry_run; then
    : >"$VUB_LOG_FILE"
    chmod 0600 "$VUB_LOG_FILE"
  fi
  info "开始阶段：$VUB_PHASE_NAME"
}

mark_named_phase() {
  local phase="$1" status="$2" detail="${3:-}"
  [[ "$phase" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "阶段名称不安全：$phase"
  if is_dry_run; then
    info "DRY-RUN: phase $phase -> $status"
    return 0
  fi
  init_runtime_dirs
  {
    printf 'phase=%q\n' "$phase"
    printf 'status=%q\n' "$status"
    printf 'date=%q\n' "$(_vub_timestamp)"
    printf 'detail=%q\n' "$detail"
  } >"$VUB_STATE_DIR/${phase}.state"
  chmod 0600 "$VUB_STATE_DIR/${phase}.state"
}

mark_phase() {
  mark_named_phase "$VUB_PHASE_NAME" "$@"
}

safe_backup_target() {
  local path="$1"
  [[ "$path" == /* ]] || return 1
  [[ "$path" != "/" && "$path" != "/etc" && "$path" != "/var" && "$path" != "/home" && "$path" != "/root" ]] || return 1
  [[ "$path" != /proc/* && "$path" != /sys/* && "$path" != /dev/* && "$path" != /run/* ]] || return 1
  [[ "$path" != *$'\n'* && "$path" != *$'\t'* ]] || return 1
}

init_backup_dir() {
  [[ -n "$VUB_BACKUP_DIR" ]] && return 0
  if ! is_dry_run && [[ -r "$VUB_STATE_DIR/active-backup" ]]; then
    local active_candidate active_phase
    active_candidate="$(<"$VUB_STATE_DIR/active-backup")"
    active_phase="$(sed -nE 's/^phase=(.*)$/\1/p' "$active_candidate/MANIFEST.txt" 2>/dev/null | head -n1)"
    if [[ -d "$active_candidate" && "$active_phase" == "$VUB_PHASE_NAME" ]]; then
      VUB_BACKUP_DIR="$active_candidate"
      export VUB_BACKUP_DIR
      return 0
    fi
  fi
  local stamp safe_phase
  stamp="$(date '+%Y%m%d-%H%M%S')"
  safe_phase="${VUB_PHASE_NAME//[^A-Za-z0-9_.-]/_}"
  VUB_BACKUP_DIR="$VUB_BACKUP_ROOT/${stamp}-${safe_phase}"
  export VUB_BACKUP_DIR
  if is_dry_run; then
    info "DRY-RUN: create backup $VUB_BACKUP_DIR"
    return 0
  fi
  install -d -m 0700 -o root -g root "$VUB_BACKUP_DIR/rootfs"
  {
    printf 'phase=%s\n' "$VUB_PHASE_NAME"
    printf 'date=%s\n' "$(_vub_timestamp)"
    printf 'config=%s\n' "$VUB_CONFIG_FILE"
  } >"$VUB_BACKUP_DIR/MANIFEST.txt"
  : >"$VUB_BACKUP_DIR/paths.tsv"
  printf '%s\n' "$VUB_BACKUP_DIR" >"$VUB_STATE_DIR/active-backup"
}

backup_path() {
  local path="$1"
  safe_backup_target "$path" || die "拒绝备份不安全路径：$path"
  init_backup_dir
  if is_dry_run; then
    info "DRY-RUN: backup $path"
    return 0
  fi
  if awk -F '\t' -v p="$path" '$2 == p {found=1} END {exit !found}' "$VUB_BACKUP_DIR/paths.tsv"; then
    return 0
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    local dest="$VUB_BACKUP_DIR/rootfs/${path#/}"
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$path" "$dest"
    printf 'present\t%s\n' "$path" >>"$VUB_BACKUP_DIR/paths.tsv"
    if [[ -f "$path" && ! -L "$path" ]]; then
      sha256sum -- "$path" >>"$VUB_BACKUP_DIR/SHA256SUMS" 2>/dev/null || true
    fi
  else
    printf 'absent\t%s\n' "$path" >>"$VUB_BACKUP_DIR/paths.tsv"
  fi
}

complete_backup() {
  if [[ -z "$VUB_BACKUP_DIR" && -r "$VUB_STATE_DIR/active-backup" ]]; then
    VUB_BACKUP_DIR="$(<"$VUB_STATE_DIR/active-backup")"
    export VUB_BACKUP_DIR
  fi
  [[ -n "$VUB_BACKUP_DIR" ]] || return 0
  if is_dry_run; then
    return 0
  fi
  printf '%s\n' "$VUB_BACKUP_DIR" >"$VUB_STATE_DIR/last-backup"
  rm -f "$VUB_STATE_DIR/active-backup"
}

write_managed_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-root}" group="${4:-root}"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  backup_path "$path"
  if is_dry_run; then
    info "DRY-RUN: install managed file $path"
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  local target_tmp
  target_tmp="$(mktemp "$(dirname "$path")/.vub.$(basename "$path").XXXXXX")"
  install -m "$mode" -o "$owner" -g "$group" "$tmp" "$target_tmp"
  mv -fT "$target_tmp" "$path"
  rm -f "$tmp"
}

write_user_file() {
  local path="$1" mode="${2:-0600}"
  [[ -n "$REAL_USER" ]] || resolve_real_user
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  backup_path "$path"
  if is_dry_run; then
    info "DRY-RUN: install user file $path"
    rm -f "$tmp"
    return 0
  fi
  local parent
  parent="$(dirname "$path")"
  if [[ -d "$parent" ]]; then
    [[ "$(stat -c %U "$parent")" == "$REAL_USER" ]] \
      || die "用户文件父目录不属于 $REAL_USER：$parent"
  else
    install -d -m 0700 -o "$REAL_USER" -g "$REAL_GROUP" "$parent"
  fi
  local target_tmp
  target_tmp="$(mktemp "$parent/.vub.$(basename "$path").XXXXXX")"
  install -m "$mode" -o "$REAL_USER" -g "$REAL_GROUP" "$tmp" "$target_tmp"
  mv -fT "$target_tmp" "$path"
  rm -f "$tmp"
}

remove_managed_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  backup_path "$path"
  if is_dry_run; then
    info "DRY-RUN: remove $path"
  else
    rm -rf -- "$path"
  fi
}

replace_marked_block() {
  local path="$1" begin="$2" end="$3" mode="${4:-0644}" owner="${5:-root}" group="${6:-root}"
  local block_tmp out_tmp
  block_tmp="$(mktemp)"
  out_tmp="$(mktemp)"
  cat >"$block_tmp"
  python3 - "$path" "$begin" "$end" "$block_tmp" >"$out_tmp" <<'PY'
import pathlib
import sys

path, begin, end, block_path = sys.argv[1:]
original = pathlib.Path(path).read_text(encoding="utf-8") if pathlib.Path(path).exists() else ""
block = pathlib.Path(block_path).read_text(encoding="utf-8").rstrip("\n")
lines = original.splitlines()
if lines.count(begin) != lines.count(end) or lines.count(begin) > 1:
    raise SystemExit(f"ambiguous or unmatched managed markers in {path}")
kept = []
inside = False
for line in lines:
    if line == begin:
        inside = True
        continue
    if inside and line == end:
        inside = False
        continue
    if not inside:
        kept.append(line)
while kept and not kept[-1].strip():
    kept.pop()
if kept:
    kept.append("")
kept.extend([begin, block, end])
print("\n".join(kept))
PY
  write_managed_file "$path" "$mode" "$owner" "$group" <"$out_tmp"
  rm -f "$block_tmp" "$out_tmp"
}

remove_marked_block() {
  local path="$1" begin="$2" end="$3" mode="${4:-0644}" owner="${5:-root}" group="${6:-root}"
  [[ -f "$path" ]] || return 0
  local out_tmp
  out_tmp="$(mktemp)"
  python3 - "$path" "$begin" "$end" >"$out_tmp" <<'PY'
import pathlib
import sys

path, begin, end = sys.argv[1:]
lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
if lines.count(begin) != lines.count(end) or lines.count(begin) > 1:
    raise SystemExit(f"ambiguous or unmatched managed markers in {path}")
kept = []
inside = False
for line in lines:
    if line == begin:
        inside = True
        continue
    if inside and line == end:
        inside = False
        continue
    if not inside:
        kept.append(line)
while kept and not kept[-1].strip():
    kept.pop()
if kept:
    print("\n".join(kept))
PY
  write_managed_file "$path" "$mode" "$owner" "$group" <"$out_tmp"
  rm -f "$out_tmp"
}

render_template() {
  local template="$1"
  shift
  python3 - "$template" "$@" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for item in sys.argv[2:]:
    key, sep, value = item.partition("=")
    if not sep:
        raise SystemExit(f"bad template assignment: {item}")
    text = text.replace("{{" + key + "}}", value)
if "{{" in text or "}}" in text:
    raise SystemExit("unresolved template placeholder")
sys.stdout.write(text)
PY
}

load_proxy_state() {
  local path="$VUB_ETC_DIR/proxy.env"
  [[ -r "$path" ]] || return 1
  # shellcheck disable=SC1090
  source "$path"
  export http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
}

record_reboot_required() {
  if is_dry_run; then
    info "DRY-RUN: mark reboot required"
  else
    printf '%s\n' "$(_vub_timestamp)" >"$VUB_STATE_DIR/reboot-required"
  fi
}

clear_reboot_required() {
  is_dry_run || rm -f "$VUB_STATE_DIR/reboot-required"
}

if is_true "$VUB_TESTING"; then
  :
fi
