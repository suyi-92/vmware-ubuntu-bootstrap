#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

remote_bootstrap() {
  local official_url="https://github.com/suyi-92/vmware-ubuntu-bootstrap.git"
  local repository_url="${VUB_REPOSITORY_URL:-$official_url}"
  local install_dir="${VUB_INSTALL_DIR:-$HOME/vmware-ubuntu-bootstrap}"
  local origin branch stage_dir=""

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    printf '请以普通 Ubuntu 用户运行远程一键命令；安装器会在需要时自行调用 sudo。\n' >&2
    exit 1
  fi
  [[ "$install_dir" == "$HOME/"* && "$install_dir" != "$HOME" ]] || {
    printf 'VUB_INSTALL_DIR 必须是用户主目录下的独立绝对路径。\n' >&2
    exit 1
  }
  command -v sudo >/dev/null 2>&1 || {
    printf '缺少 sudo，无法安装启动依赖。\n' >&2
    exit 1
  }

  if ! command -v git >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || {
      printf '缺少 git 和 apt-get，无法下载完整项目。\n' >&2
      exit 1
    }
    printf '正在安装远程启动所需的 git...\n'
    sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY \
      env DEBIAN_FRONTEND=noninteractive apt-get update
    sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY \
      env DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
  fi

  if [[ -e "$install_dir" ]]; then
    [[ -d "$install_dir/.git" ]] || {
      printf '安装目录已存在但不是 Git 仓库：%s\n' "$install_dir" >&2
      exit 1
    }
    origin="$(git -C "$install_dir" remote get-url origin 2>/dev/null || true)"
    if [[ "$repository_url" == "$official_url" ]]; then
      case "$origin" in
        "$official_url"|https://github.com/suyi-92/vmware-ubuntu-bootstrap|git@github.com:suyi-92/vmware-ubuntu-bootstrap.git) ;;
        *) printf '安装目录的 origin 不是本项目仓库：%s\n' "$origin" >&2; exit 1 ;;
      esac
    elif [[ "$origin" != "$repository_url" ]]; then
      printf '安装目录的 origin 与 VUB_REPOSITORY_URL 不一致。\n' >&2
      exit 1
    fi
    [[ -z "$(git -C "$install_dir" status --porcelain --untracked-files=all)" ]] || {
      printf '安装目录存在本地修改，请先处理后再运行一键命令：%s\n' "$install_dir" >&2
      exit 1
    }
    branch="$(git -C "$install_dir" branch --show-current)"
    [[ "$branch" == "main" ]] || {
      printf '安装目录当前分支不是 main：%s\n' "$branch" >&2
      exit 1
    }
    git -C "$install_dir" pull --ff-only origin main
  else
    mkdir -p -- "$(dirname -- "$install_dir")"
    stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/vmware-ubuntu-bootstrap.XXXXXX")"
    cleanup_remote_stage() {
      if [[ -n "${stage_dir:-}" && -d "$stage_dir" ]]; then
        rm -rf -- "$stage_dir"
      fi
    }
    trap cleanup_remote_stage EXIT
    git clone --depth 1 --branch main -- "$repository_url" "$stage_dir/repository"
    mv -- "$stage_dir/repository" "$install_dir"
    rmdir -- "$stage_dir"
    stage_dir=""
    trap - EXIT
  fi

  printf '项目已准备到：%s\n' "$install_dir"
  exec bash "$install_dir/install.sh" "$@"
}

if [[ ! -r "$PROJECT_DIR/scripts/00-lib.sh" ]]; then
  remote_bootstrap "$@"
fi

# shellcheck source=scripts/00-lib.sh
source "$PROJECT_DIR/scripts/00-lib.sh"

MODE="full"
PHASE=""
ROLLBACK_ID=""
CONFIG_WAS_EXPLICIT="false"
ORIGINAL_ARGS=("$@")
VUB_TEMP_CONFIG=""
VUB_TEMP_SECRET=""
cleanup_install_temps() {
  if [[ -n "${VUB_TEMP_CONFIG:-}" ]]; then
    rm -f "$VUB_TEMP_CONFIG"
  fi
  if [[ -n "${VUB_TEMP_SECRET:-}" ]]; then
    rm -f "$VUB_TEMP_SECRET"
  fi
}
trap cleanup_install_temps EXIT

usage() {
  cat <<'EOF'
VMware Ubuntu Bootstrap

用法：
  sudo bash install.sh
  sudo bash install.sh --phase <phase>
  sudo bash install.sh --status
  sudo bash install.sh --rollback-last
  sudo bash install.sh --rollback <backup-id-or-path>
  sudo bash install.sh --config config.env --yes

选项：
  --config PATH   使用指定配置
  --phase NAME    只执行一个阶段
  --dry-run       只显示计划，不写系统
  --yes, -y       接受普通确认；不会绕过网络和 SSH 高风险门槛
  --verbose       输出完整命令日志
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --config) VUB_CONFIG_FILE="${2:-}"; CONFIG_WAS_EXPLICIT="true"; shift 2 ;;
    --phase) MODE="phase"; PHASE="${2:-}"; shift 2 ;;
    --status) MODE="phase"; PHASE="status"; shift ;;
    --rollback-last) MODE="phase"; PHASE="rollback"; ROLLBACK_ID="last"; shift ;;
    --rollback) MODE="phase"; PHASE="rollback"; ROLLBACK_ID="${2:-}"; shift 2 ;;
    --dry-run) VUB_DRY_RUN="true"; shift ;;
    --yes|-y) VUB_YES="true"; shift ;;
    --verbose) VUB_VERBOSE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [[ "$VUB_CONFIG_FILE" != /* ]]; then
  VUB_CONFIG_FILE="$(cd -- "$(dirname -- "$VUB_CONFIG_FILE")" && pwd -P)/$(basename -- "$VUB_CONFIG_FILE")"
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -E bash "$0" "${ORIGINAL_ARGS[@]}"
fi

export VUB_CONFIG_FILE VUB_DRY_RUN VUB_YES VUB_VERBOSE

if [[ "$MODE" == "phase" ]]; then
  args=(--phase "$PHASE" --config "$VUB_CONFIG_FILE")
  is_true "$VUB_DRY_RUN" && args+=(--dry-run)
  is_true "$VUB_YES" && args+=(--yes)
  is_true "$VUB_VERBOSE" && args+=(--verbose)
  [[ -n "$ROLLBACK_ID" ]] && args+=(--backup "$ROLLBACK_ID")
  exec bash "$PROJECT_DIR/bootstrap.sh" "${args[@]}"
fi

banner() {
  printf '%b\n' "${VUB_CYAN}${VUB_BOLD}"
  cat <<'EOF'
╭────────────────────────────────────────────────╮
│          VMware Ubuntu Bootstrap               │
│  Proxy · Network · Power · SSH · Codex/CPA    │
╰────────────────────────────────────────────────╯
EOF
  printf '%b' "$VUB_RESET"
}

emit_config() {
  printf '# Generated by install.sh. Do not commit.\n'
  printf 'TARGET_USER=%s\n' "$(shell_quote "$TARGET_USER")"
  printf 'NETWORK_INTERFACE=%s\n' "$(shell_quote "$NETWORK_INTERFACE")"
  printf 'PROXY_HOST=%s\n' "$(shell_quote "$PROXY_HOST")"
  printf 'PROXY_PORT=%s\n' "$(shell_quote "$PROXY_PORT")"
  printf 'PROXY_SCAN_CIDR=%s\n' "$(shell_quote "$PROXY_SCAN_CIDR")"
  printf 'CONFIGURE_STATIC_NETWORK=%s\n' "$(shell_quote "$CONFIGURE_STATIC_NETWORK")"
  printf 'STATIC_IPV4_PREFIX=%s\n' "$(shell_quote "$STATIC_IPV4_PREFIX")"
  printf 'STATIC_IPV4_LAST_OCTET=%s\n' "$(shell_quote "$STATIC_IPV4_LAST_OCTET")"
  printf 'PREFIX_LENGTH=%s\n' "$(shell_quote "$PREFIX_LENGTH")"
  printf 'GATEWAY_IPV4=%s\n' "$(shell_quote "$GATEWAY_IPV4")"
  printf 'DNS_SERVERS=%s\n' "$(shell_quote "$DNS_SERVERS")"
  printf 'ALLOW_SSH_NETWORK_CHANGE=%s\n' "$(shell_quote "$ALLOW_SSH_NETWORK_CHANGE")"
  printf 'HOSTNAME=%s\n' "$(shell_quote "$HOSTNAME")"
  printf 'TIMEZONE=%s\n' "$(shell_quote "$TIMEZONE")"
  printf 'SSH_PORT=%s\n' "$(shell_quote "$SSH_PORT")"
  printf 'ADMIN_PUBKEYS=%s\n' "$(shell_quote "$ADMIN_PUBKEYS")"
  printf 'ENABLE_UFW=%s\n' "$(shell_quote "$ENABLE_UFW")"
  printf 'DISABLE_SSH_PASSWORD=%s\n' "$(shell_quote "$DISABLE_SSH_PASSWORD")"
  printf 'CONFIRM_SSH_KEY_LOGIN=%s\n' "$(shell_quote "$CONFIRM_SSH_KEY_LOGIN")"
  printf 'CONFIGURE_CODEX=%s\n' "$(shell_quote "$CONFIGURE_CODEX")"
  printf 'CPA_BASE_URL=%s\n' "$(shell_quote "$CPA_BASE_URL")"
  printf 'CPA_MODEL_ID=%s\n' "$(shell_quote "$CPA_MODEL_ID")"
  printf 'RUN_CPA_SMOKE=%s\n' "$(shell_quote "$RUN_CPA_SMOKE")"
  printf 'RUN_CODEX_SMOKE=%s\n' "$(shell_quote "$RUN_CODEX_SMOKE")"
  printf 'INSTALL_DOCKER=%s\n' "$(shell_quote "$INSTALL_DOCKER")"
}

bool_prompt() {
  local prompt="$1" default_value="$2"
  if read_yes_no "$prompt" "$([[ "$default_value" == "true" ]] && printf yes || printf no)"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

collect_config() {
  init_input_tty
  load_config false
  banner

  local detected_user detected_iface detected_ip detected_gateway detected_dns existing_key_file secret_file secret_exists="false" key_input=""
  detected_user="${TARGET_USER:-${SUDO_USER:-}}"
  TARGET_USER="$(read_default "要配置的 Ubuntu 登录用户（通常直接回车）" "$detected_user")"
  resolve_real_user

  detected_iface="$(current_interface)"
  NETWORK_INTERFACE="$(read_default "桥接网卡" "${NETWORK_INTERFACE:-$detected_iface}")"
  detected_ip="$(current_ipv4 "$NETWORK_INTERFACE")"
  [[ -n "$detected_ip" ]] || die "无法读取 $NETWORK_INTERFACE 的 IPv4。"
  detected_gateway="$(current_gateway)"
  detected_dns="$(current_dns_servers "$NETWORK_INTERFACE")"

  printf '\n%b\n' "${VUB_CYAN}${VUB_BOLD}代理${VUB_RESET}"
  PROXY_HOST="$(read_default "代理主机（留空自动发现）" "$PROXY_HOST")"
  PROXY_PORT="$(read_default "代理端口" "$PROXY_PORT")"
  PROXY_SCAN_CIDR="$(read_default "代理扫描网段" "${PROXY_SCAN_CIDR:-$(cidr24_for_ip "$detected_ip")}")"

  printf '\n%b\n' "${VUB_CYAN}${VUB_BOLD}固定网络${VUB_RESET}"
  CONFIGURE_STATIC_NETWORK="$(bool_prompt "配置固定桥接 IP" "$CONFIGURE_STATIC_NETWORK")"
  STATIC_IPV4_PREFIX="192.168.1"
  STATIC_IPV4_LAST_OCTET="$(read_default "固定 IPv4 末位（255 不可用）" "$STATIC_IPV4_LAST_OCTET")"
  PREFIX_LENGTH="24"
  GATEWAY_IPV4="$(read_default "默认网关" "${GATEWAY_IPV4:-$detected_gateway}")"
  DNS_SERVERS="$(read_default "DNS（空格分隔）" "${DNS_SERVERS:-$detected_dns}")"
  HOSTNAME="$(read_default "主机名（留空保持当前）" "${HOSTNAME:-$(hostname)}")"
  TIMEZONE="$(read_default "时区" "$TIMEZONE")"

  printf '\n%b\n' "${VUB_CYAN}${VUB_BOLD}SSH${VUB_RESET}"
  SSH_PORT="$(read_default "SSH 端口" "$SSH_PORT")"
  existing_key_file="$REAL_HOME/.ssh/authorized_keys"
  if [[ -z "$ADMIN_PUBKEYS" && -r "$existing_key_file" ]]; then
    ADMIN_PUBKEYS="$(grep -E '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-ssh-)' "$existing_key_file" || true)"
  fi
  if [[ -n "$ADMIN_PUBKEYS" ]] && read_yes_no "保留已配置的 SSH 公钥" yes; then
    :
  else
    ADMIN_PUBKEYS="$(read_default "粘贴 Windows SSH 公钥" "")"
  fi
  [[ -n "$ADMIN_PUBKEYS" ]] || die "至少需要一个 SSH 公钥。"
  ENABLE_UFW="$(bool_prompt "开启 UFW（默认不开）" "$ENABLE_UFW")"
  DISABLE_SSH_PASSWORD="$(bool_prompt "已验证公钥登录并关闭 SSH 密码认证" "$DISABLE_SSH_PASSWORD")"
  if is_true "$DISABLE_SSH_PASSWORD"; then
    CONFIRM_SSH_KEY_LOGIN="$(bool_prompt "确认已从第二终端完成公钥登录" "$CONFIRM_SSH_KEY_LOGIN")"
  else
    CONFIRM_SSH_KEY_LOGIN="false"
  fi

  printf '\n%b\n' "${VUB_CYAN}${VUB_BOLD}Codex / CPA${VUB_RESET}"
  CONFIGURE_CODEX="$(bool_prompt "安装并配置 Codex" "$CONFIGURE_CODEX")"
  if is_true "$CONFIGURE_CODEX"; then
    CPA_BASE_URL="$(read_default "CPA /v1 地址" "$CPA_BASE_URL")"
    CPA_BASE_URL="$(validate_cpa_url "$CPA_BASE_URL")"
    CPA_MODEL_ID="$(read_default "CPA 模型 ID" "$CPA_MODEL_ID")"
    secret_file="$REAL_HOME/.config/vmware-ubuntu-bootstrap/secrets/cpa-api-key"
    [[ -s "$secret_file" ]] && secret_exists="true"
    key_input="$(read_secret "CPA API key" "$secret_exists")"
    if [[ -z "$key_input" && "$secret_exists" != "true" ]]; then
      die "首次配置必须输入 CPA API key。"
    fi
    if [[ -n "$key_input" ]]; then
      umask 077
      VUB_TEMP_SECRET="$(mktemp /run/vmware-ubuntu-bootstrap-cpa.XXXXXX)"
      printf '%s\n' "$key_input" >"$VUB_TEMP_SECRET"
      chmod 0600 "$VUB_TEMP_SECRET"
      VUB_CPA_API_KEY_FILE="$VUB_TEMP_SECRET"
      export VUB_CPA_API_KEY_FILE
      key_input=""
    fi
    RUN_CPA_SMOKE="$(bool_prompt "发送一次最小 CPA Responses 验证请求" "$RUN_CPA_SMOKE")"
    RUN_CODEX_SMOKE="$(bool_prompt "执行一次最小 codex exec 验证" "$RUN_CODEX_SMOKE")"
  fi

  INSTALL_DOCKER="$(bool_prompt "安装 Docker（首版默认不安装）" "$INSTALL_DOCKER")"
  validate_config
}

write_config_file() {
  start_phase "config"
  if is_dry_run; then
    local tmp_config
    tmp_config="$(mktemp)"
    emit_config >"$tmp_config"
    chmod 0600 "$tmp_config"
    VUB_TEMP_CONFIG="$tmp_config"
    VUB_CONFIG_FILE="$tmp_config"
    export VUB_CONFIG_FILE
    info "DRY-RUN 使用临时配置：$tmp_config"
  else
    emit_config | write_managed_file "$VUB_CONFIG_FILE" 0600 root root
    complete_backup
    mark_phase complete "config written"
  fi
}

show_summary() {
  cat <<EOF

即将应用：
  用户：        $TARGET_USER
  网卡：        $NETWORK_INTERFACE
  代理：        ${PROXY_HOST:-自动发现}:$PROXY_PORT（$PROXY_SCAN_CIDR）
  固定 IP：     $STATIC_IPV4_PREFIX.$STATIC_IPV4_LAST_OCTET/$PREFIX_LENGTH
  网关：        $GATEWAY_IPV4
  DNS：         $DNS_SERVERS
  SSH：         tcp/$SSH_PORT，UFW=$ENABLE_UFW
  Codex：       $CONFIGURE_CODEX，CPA=${CPA_BASE_URL:-未配置}，模型=${CPA_MODEL_ID:-未配置}
  API key：     <redacted>
EOF
}

if is_true "$CONFIG_WAS_EXPLICIT" && is_true "$VUB_YES"; then
  load_config true
  resolve_real_user
  validate_config
else
  collect_config
  show_summary
  if ! is_true "$VUB_YES" && ! read_yes_no "确认开始配置" yes; then
    die "用户取消。"
  fi
  write_config_file
fi

args=(--phase full --config "$VUB_CONFIG_FILE")
is_true "$VUB_DRY_RUN" && args+=(--dry-run)
is_true "$VUB_YES" && args+=(--yes)
is_true "$VUB_VERBOSE" && args+=(--verbose)
bash "$PROJECT_DIR/bootstrap.sh" "${args[@]}"
