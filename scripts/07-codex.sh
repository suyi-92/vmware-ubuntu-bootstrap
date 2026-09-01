#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "codex"
require_root
load_config true
resolve_real_user

if ! is_true "$CONFIGURE_CODEX"; then
  mark_phase skipped "disabled by config"
  info "按配置跳过 Codex。"
  exit 0
fi

require_command curl
require_command python3
CPA_BASE_URL="$(validate_cpa_url "$CPA_BASE_URL")"
[[ -n "$CPA_MODEL_ID" ]] || die "CPA_MODEL_ID 不能为空。"
load_proxy_state || warn "没有持久化代理状态；Codex 安装将使用当前环境或直连。"

USER_CONFIG_ROOT="$REAL_HOME/.config/vmware-ubuntu-bootstrap"
SECRET_DIR="$USER_CONFIG_ROOT/secrets"
KEY_FILE="$SECRET_DIR/cpa-api-key"
TOKEN_HELPER="$REAL_HOME/.local/libexec/vmware-ubuntu-bootstrap-codex-token"
CODEX_DIR="$REAL_HOME/.codex"
MAIN_CONFIG="$CODEX_DIR/config.toml"
LEGACY_PROFILE="$CODEX_DIR/cpa.config.toml"
LEGACY_WRAPPER="$REAL_HOME/.local/bin/codex-cpa"
LEGACY_TOKEN_HELPER="$REAL_HOME/.local/libexec/codex-cpa-token"

if [[ -n "${VUB_CPA_API_KEY_FILE:-}" ]]; then
  [[ -f "$VUB_CPA_API_KEY_FILE" && -r "$VUB_CPA_API_KEY_FILE" ]] \
    || die "临时 CPA key 文件不可读。"
  write_user_file "$KEY_FILE" 0600 <"$VUB_CPA_API_KEY_FILE"
elif [[ ! -s "$KEY_FILE" ]]; then
  if is_true "$VUB_YES"; then
    die "没有现有 CPA key；非交互模式请预先创建 0600 凭据文件。"
  fi
  init_input_tty
  CPA_KEY_INPUT="$(read_secret "CPA API key" false)"
  [[ -n "$CPA_KEY_INPUT" ]] || die "CPA API key 不能为空。"
  printf '%s\n' "$CPA_KEY_INPUT" | write_user_file "$KEY_FILE" 0600
  unset CPA_KEY_INPUT
fi

if ! is_dry_run; then
  [[ "$(stat -c '%U:%G:%a' "$KEY_FILE")" == "$REAL_USER:$REAL_GROUP:600" ]] \
    || die "CPA key 权限不符合 user:group:600。"
fi

{
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
KEY_FILE=$(shell_quote "$KEY_FILE")
[[ -r "\$KEY_FILE" ]] || { echo "CPA key file is not readable" >&2; exit 1; }
tr -d '\\r\\n' <"\$KEY_FILE"
EOF
} | write_user_file "$TOKEN_HELPER" 0700

CODEX_BIN="$REAL_HOME/.local/bin/codex"
[[ -x "$CODEX_BIN" ]] || CODEX_BIN="$REAL_HOME/.codex/bin/codex"
if [[ ! -x "$CODEX_BIN" ]]; then
  existing_codex="$(run_as_user bash -c 'command -v codex || true')"
  [[ -n "$existing_codex" ]] && CODEX_BIN="$existing_codex"
fi

if [[ ! -x "$CODEX_BIN" ]]; then
  if is_dry_run; then
    info "DRY-RUN: download and run https://chatgpt.com/codex/install.sh as $REAL_USER"
    CODEX_BIN="$REAL_HOME/.local/bin/codex"
  else
    backup_path "$REAL_HOME/.local/bin/codex"
    backup_path "$REAL_HOME/.local/bin/codex-code-mode-host"
    backup_path "$REAL_HOME/.codex/packages/standalone"
    INSTALLER_TMP="$(mktemp)"
    trap 'rm -f "${INSTALLER_TMP:-}" "${CONFIG_TMP:-}"' EXIT
    curl -fsSL --connect-timeout 10 --max-time 120 https://chatgpt.com/codex/install.sh -o "$INSTALLER_TMP"
    [[ -s "$INSTALLER_TMP" ]] || die "Codex 官方安装脚本下载为空。"
    head -n 1 "$INSTALLER_TMP" | grep -Eq '^#!' || die "Codex 安装脚本缺少 shebang。"
    chown "$REAL_USER:$REAL_GROUP" "$INSTALLER_TMP"
    run_as_user sh "$INSTALLER_TMP"
    CODEX_BIN="$REAL_HOME/.local/bin/codex"
    [[ -x "$CODEX_BIN" ]] || CODEX_BIN="$(run_as_user bash -c 'command -v codex || true')"
    [[ -x "$CODEX_BIN" ]] || die "Codex 安装后找不到可执行文件。"
  fi
else
  info "检测到 Codex：$CODEX_BIN"
fi

CONFIG_TMP="$(mktemp)"
python3 "$SCRIPT_DIR/render_codex_config.py" \
  --model "$CPA_MODEL_ID" --base-url "$CPA_BASE_URL" --token-helper "$TOKEN_HELPER" >"$CONFIG_TMP"
if [[ -e "$MAIN_CONFIG" ]] && ! grep -Fq '# Managed by vmware-ubuntu-bootstrap.' "$MAIN_CONFIG" 2>/dev/null; then
  warn "现有 $MAIN_CONFIG 将备份后由本项目接管，使标准 codex 命令默认使用 CPA。"
fi
write_user_file "$MAIN_CONFIG" 0600 <"$CONFIG_TMP"
rm -f "$CONFIG_TMP"

remove_managed_path "$LEGACY_PROFILE"
remove_managed_path "$LEGACY_WRAPPER"
remove_managed_path "$LEGACY_TOKEN_HELPER"

if ! is_dry_run; then
  run_as_user python3 - "$MAIN_CONFIG" <<'PY'
import pathlib
import sys
import tomllib
with pathlib.Path(sys.argv[1]).open("rb") as handle:
    data = tomllib.load(handle)
assert data["model_provider"] == "cpa"
assert data["model_providers"]["cpa"]["wire_api"] == "responses"
assert "experimental_bearer_token" not in data["model_providers"]["cpa"]
PY

  run_as_user python3 "$SCRIPT_DIR/cpa_client.py" models \
    --base-url "$CPA_BASE_URL" --key-file "$KEY_FILE" --model "$CPA_MODEL_ID"

  if is_true "$RUN_CPA_SMOKE"; then
    warn "发送一次最小 CPA Responses 请求，可能产生少量 API 费用。"
    run_as_user python3 "$SCRIPT_DIR/cpa_client.py" responses \
      --base-url "$CPA_BASE_URL" --key-file "$KEY_FILE" --model "$CPA_MODEL_ID"
  fi

  run_as_user "$CODEX_BIN" --version
  if is_true "$RUN_CODEX_SMOKE"; then
    warn "执行一次最小 codex exec 请求，可能产生少量 API 费用。"
    run_as_user timeout 120 "$CODEX_BIN" exec --skip-git-repo-check \
      "Reply exactly OK." >/dev/null
  fi
fi

complete_backup
mark_phase complete "provider=cpa;model=$CPA_MODEL_ID;config=$MAIN_CONFIG"
info "Codex/CPA 配置完成。请直接运行：codex"
