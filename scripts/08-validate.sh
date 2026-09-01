#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "validate"
require_root
load_config true
resolve_real_user
validate_config

if is_dry_run; then
  info "DRY-RUN: 配置合同通过；跳过依赖真实系统状态的最终验收。"
  exit 0
fi

OS_RELEASE_FILE="${VUB_OS_RELEASE_FILE:-/etc/os-release}"
# shellcheck disable=SC1090
source "$OS_RELEASE_FILE"
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "系统版本验收失败。"

systemctl is-active --quiet open-vm-tools || die "open-vm-tools 未运行。"
for vmware_package in open-vm-tools open-vm-tools-desktop; do
  dpkg-query -W -f='${Status}\n' "$vmware_package" 2>/dev/null \
    | grep -Fxq 'install ok installed' \
    || die "VMware 集成包未安装：$vmware_package"
done
command -v vmware-user-suid-wrapper >/dev/null 2>&1 \
  || die "VMware 桌面代理入口不存在。"
[[ -r /etc/xdg/autostart/vmware-user.desktop ]] \
  || die "VMware 桌面代理自动启动项不存在。"
if command -v pgrep >/dev/null 2>&1; then
  if ! pgrep -a -u "$REAL_UID" -x vmtoolsd 2>/dev/null \
      | grep -Eq '[[:space:]]-n[[:space:]]+vmusr([[:space:]]|$)' \
    && ! pgrep -u "$REAL_UID" -f '(^|/)(vmware-user|vmware-user-suid-wrapper)([[:space:]]|$)' >/dev/null; then
    warn "VMware 桌面代理尚未在图形会话中运行；请登录 Ubuntu 桌面或重启后复验复制粘贴。"
  fi
fi
systemctl is-active --quiet ssh.socket 2>/dev/null \
  || systemctl is-active --quiet ssh 2>/dev/null \
  || systemctl is-active --quiet sshd 2>/dev/null \
  || die "SSH socket/service 未运行。"

load_proxy_state || die "代理状态文件不存在。"
curl -fsSI --connect-timeout 5 --max-time 20 https://github.com/ >/dev/null \
  || die "root curl 代理验收失败。"
run_as_user curl -fsSI --connect-timeout 5 --max-time 20 https://github.com/ >/dev/null \
  || die "普通用户 curl 代理验收失败。"
if command -v wget >/dev/null 2>&1; then
  wget -q --spider --timeout=20 https://github.com/ \
    || die "root wget 代理验收失败。"
  run_as_user wget -q --spider --timeout=20 https://github.com/ \
    || die "普通用户 wget 代理验收失败。"
fi

EXPECTED_PROXY="${http_proxy:-}"
[[ -n "$EXPECTED_PROXY" ]] || die "代理 URL 为空。"
[[ "${https_proxy:-}" == "$EXPECTED_PROXY" && "${all_proxy:-}" == "$EXPECTED_PROXY" ]] \
  || die "HTTP/HTTPS/ALL_PROXY 状态不一致。"
[[ "$(git config --get http.proxy 2>/dev/null || true)" == "$EXPECTED_PROXY" ]] \
  || die "系统 Git 代理验收失败。"
[[ "$(run_as_user git config --get http.proxy 2>/dev/null || true)" == "$EXPECTED_PROXY" ]] \
  || die "用户 Git 代理验收失败。"
[[ "$(HOME=/root git config --get http.proxy 2>/dev/null || true)" == "$EXPECTED_PROXY" ]] \
  || die "root Git 代理验收失败。"
apt-config dump 2>/dev/null | grep -Fq "$EXPECTED_PROXY" || die "APT 代理验收失败。"
visudo -cf /etc/sudoers >/dev/null || die "sudoers 语法验收失败。"
grep -Fq 'all_proxy ALL_PROXY' /etc/sudoers.d/90-vmware-ubuntu-bootstrap-proxy-env \
  || die "sudo 代理环境保留规则验收失败。"
systemctl show-environment 2>/dev/null | grep -Fxq "ALL_PROXY=$EXPECTED_PROXY" \
  || die "systemd ALL_PROXY 验收失败。"

if command -v snap >/dev/null 2>&1; then
  [[ "$(snap get system proxy.http 2>/dev/null || true)" == "$EXPECTED_PROXY" ]] \
    || die "Snap HTTP 代理验收失败。"
  [[ "$(snap get system proxy.https 2>/dev/null || true)" == "$EXPECTED_PROXY" ]] \
    || die "Snap HTTPS 代理验收失败。"
fi

if is_true "$INSTALL_DOCKER"; then
  command -v docker >/dev/null 2>&1 || die "Docker CLI 未安装。"
  systemctl is-active --quiet docker || die "Docker daemon 未运行。"
  docker info >/dev/null 2>&1 || die "Docker daemon 不可用。"
  run_as_user docker info >/dev/null 2>&1 || die "普通用户无权访问 Docker daemon。"
  DOCKER_ENVIRONMENT="$(systemctl show docker --property=Environment --value 2>/dev/null || true)"
  grep -Fq "HTTP_PROXY=$EXPECTED_PROXY" <<<"$DOCKER_ENVIRONMENT" \
    || die "Docker daemon HTTP 代理验收失败。"
  grep -Fq "HTTPS_PROXY=$EXPECTED_PROXY" <<<"$DOCKER_ENVIRONMENT" \
    || die "Docker daemon HTTPS 代理验收失败。"
  grep -Fq "NO_PROXY=${no_proxy:-}" <<<"$DOCKER_ENVIRONMENT" \
    || die "Docker daemon NO_PROXY 验收失败。"
  python3 - /root/.docker/config.json "$REAL_HOME/.docker/config.json" \
      "$EXPECTED_PROXY" "${no_proxy:-}" <<'PY'
import json
import pathlib
import sys

root_path, user_path, proxy, no_proxy = sys.argv[1:]
expected = {"httpProxy": proxy, "httpsProxy": proxy, "noProxy": no_proxy}
for raw_path in (root_path, user_path):
    path = pathlib.Path(raw_path)
    actual = json.loads(path.read_text(encoding="utf-8")).get("proxies", {}).get("default", {})
    if actual != expected:
        raise SystemExit(f"Docker client proxy mismatch: {path}")
PY
fi

REBOOT_PENDING_FOR_CURRENT_BOOT="false"
REBOOT_OCCURRED_AFTER_MARKER="false"
if [[ -f "$VUB_STATE_DIR/reboot-required" ]]; then
  MARKER_MTIME="$(stat -c %Y "$VUB_STATE_DIR/reboot-required")"
  BOOT_TIME="$(awk '$1 == "btime" {print $2}' /proc/stat)"
  if [[ "$BOOT_TIME" =~ ^[0-9]+$ && "$MARKER_MTIME" =~ ^[0-9]+$ && "$BOOT_TIME" -gt "$MARKER_MTIME" ]]; then
    REBOOT_OCCURRED_AFTER_MARKER="true"
  else
    REBOOT_PENDING_FOR_CURRENT_BOOT="true"
  fi
fi

if is_true "$CONFIGURE_STATIC_NETWORK"; then
  STATIC_NETWORK_STATUS="$(sed -nE 's/^status=(.*)$/\1/p' "$VUB_STATE_DIR/static-network.state" 2>/dev/null | head -n1 || true)"
  if [[ "$STATIC_NETWORK_STATUS" == "pending-reboot" ]] && is_true "$REBOOT_PENDING_FOR_CURRENT_BOOT"; then
    warn "固定网络已写入磁盘；当前 SSH 地址保持不变，重启后切换到 ${STATIC_IPV4_PREFIX}.${STATIC_IPV4_LAST_OCTET}/${PREFIX_LENGTH}。"
  else
    TARGET_IPV4="${STATIC_IPV4_PREFIX}.${STATIC_IPV4_LAST_OCTET}"
    ip -4 addr show dev "$NETWORK_INTERFACE" | grep -Fq "${TARGET_IPV4}/${PREFIX_LENGTH}" \
      || die "固定 IPv4 验收失败。"
    ip -4 route show default | grep -Fq "via ${GATEWAY_IPV4}" || die "默认网关验收失败。"
    getent hosts github.com >/dev/null 2>&1 || die "DNS 验收失败。"
    if [[ "$STATIC_NETWORK_STATUS" == "pending-reboot" ]]; then
      mark_named_phase static-network complete "ip=${TARGET_IPV4}/${PREFIX_LENGTH};gateway=$GATEWAY_IPV4;activated-after-reboot"
    fi
  fi
fi

for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  [[ "$(systemctl is-enabled "$target" 2>/dev/null || true)" == "masked" ]] \
    || die "$target 尚未 mask。"
done

if command -v gsettings >/dev/null 2>&1 && [[ -S "/run/user/${REAL_UID}/bus" ]]; then
  [[ "$(run_as_user_with_bus gsettings get org.gnome.desktop.session idle-delay)" == "uint32 0" ]] \
    || die "GNOME idle-delay 验收失败。"
  [[ "$(run_as_user_with_bus gsettings get org.gnome.desktop.screensaver lock-enabled)" == "false" ]] \
    || die "GNOME lock-enabled 验收失败。"
  [[ "$(run_as_user_with_bus gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type)" == "'nothing'" ]] \
    || die "GNOME AC sleep 策略验收失败。"
fi

SSHD_BIN="${VUB_SSHD_BIN:-/usr/sbin/sshd}"
"$SSHD_BIN" -t
SSHD_EFFECTIVE="$($SSHD_BIN -T)"
grep -Fxq "port $SSH_PORT" <<<"$SSHD_EFFECTIVE" || die "sshd 有效端口验收失败。"
grep -Fxq 'permitrootlogin no' <<<"$SSHD_EFFECTIVE" || die "root SSH 禁用验收失败。"
if is_true "$DISABLE_SSH_PASSWORD"; then
  grep -Fxq 'passwordauthentication no' <<<"$SSHD_EFFECTIVE" || die "SSH 密码禁用验收失败。"
fi
ss -H -ltn4 | awk -v suffix=":$SSH_PORT" '$4 ~ (suffix "$") {found=1} END {exit !found}' \
  || die "SSH IPv4 端口未监听。"
ss -H -ltn6 | awk -v suffix=":$SSH_PORT" '$4 ~ (suffix "$") {found=1} END {exit !found}' \
  || die "SSH IPv6 端口未监听。"
grep -Fq '# BEGIN vmware-ubuntu-bootstrap keys' "$REAL_HOME/.ssh/authorized_keys" \
  || die "受管 SSH 公钥块不存在。"
if is_true "$ENABLE_UFW"; then
  ufw status | grep -Eq "${SSH_PORT}/tcp|${SSH_PORT}[[:space:]]" || die "UFW SSH 规则验收失败。"
fi

if is_true "$CONFIGURE_CODEX"; then
  KEY_FILE="$REAL_HOME/.config/vmware-ubuntu-bootstrap/secrets/cpa-api-key"
  CODEX_CONFIG="$REAL_HOME/.codex/config.toml"
  CODEX_BIN="$REAL_HOME/.local/bin/codex"
  [[ -x "$CODEX_BIN" ]] || CODEX_BIN="$REAL_HOME/.codex/bin/codex"
  if [[ ! -x "$CODEX_BIN" ]]; then
    CODEX_BIN="$(run_as_user bash -c 'command -v codex || true')"
  fi
  [[ -s "$KEY_FILE" && -x "$CODEX_BIN" && -s "$CODEX_CONFIG" ]] || die "Codex/CPA 文件不完整。"
  [[ "$(stat -c '%U:%G:%a' "$KEY_FILE")" == "$REAL_USER:$REAL_GROUP:600" ]] \
    || die "CPA key 权限验收失败。"
  run_as_user python3 - "$CODEX_CONFIG" <<'PY'
import pathlib
import sys
import tomllib
with pathlib.Path(sys.argv[1]).open("rb") as handle:
    data = tomllib.load(handle)
assert data["model_provider"] == "cpa"
assert data["model_providers"]["cpa"]["wire_api"] == "responses"
PY
  run_as_user python3 "$SCRIPT_DIR/cpa_client.py" models \
    --base-url "$CPA_BASE_URL" --key-file "$KEY_FILE" --model "$CPA_MODEL_ID"
  run_as_user "$CODEX_BIN" --version >/dev/null
  python3 "$SCRIPT_DIR/secret_guard.py" --secret-file "$KEY_FILE" \
    "$VUB_PROJECT_DIR" "$VUB_LOG_DIR" || die "API key 泄漏到仓库或日志。"
fi

FINAL_STATUS="configured-pending-reboot"
if [[ -f "$VUB_STATE_DIR/reboot-required" ]]; then
  if is_true "$REBOOT_OCCURRED_AFTER_MARKER"; then
    clear_reboot_required
    FINAL_STATUS="complete"
  fi
else
  FINAL_STATUS="complete"
fi

mark_phase "$FINAL_STATUS" "all checks passed"
if [[ "$FINAL_STATUS" == "complete" ]]; then
  info "全部验收通过。"
else
  warn "配置验收通过，但仍需重启后再次运行：sudo bash install.sh --phase validate"
  if is_true "$CONFIGURE_STATIC_NETWORK"; then
    info "重启后请从 Windows 连接：ssh -p $SSH_PORT $REAL_USER@${STATIC_IPV4_PREFIX}.${STATIC_IPV4_LAST_OCTET}"
  fi
fi
