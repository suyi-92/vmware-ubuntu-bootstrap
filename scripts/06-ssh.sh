#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "ssh"
require_root
load_config true
resolve_real_user
validate_config

require_command ssh-keygen
require_command ss
SSHD_BIN="${VUB_SSHD_BIN:-/usr/sbin/sshd}"
[[ -x "$SSHD_BIN" ]] || die "找不到 sshd：$SSHD_BIN"

PORT_LISTENERS="$(ss -H -ltnp 2>/dev/null | awk -v suffix=":$SSH_PORT" '$4 ~ (suffix "$") {print}' || true)"
SSH_SOCKET_MODE="false"
SSH_SOCKET_OWNS_PORT="false"
if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
  SSH_SOCKET_MODE="true"
  if systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -Eq ":${SSH_PORT}([^0-9]|$)"; then
    SSH_SOCKET_OWNS_PORT="true"
  fi
fi
if [[ -n "$PORT_LISTENERS" ]] && ! grep -q 'sshd' <<<"$PORT_LISTENERS" && ! is_true "$SSH_SOCKET_OWNS_PORT"; then
  printf '%s\n' "$PORT_LISTENERS" >&2
  die "SSH_PORT=$SSH_PORT 已被非 sshd 进程占用。"
fi

KEYS_TMP="$(mktemp)"
trap 'rm -f "${KEYS_TMP:-}" "${KEY_TMP:-}" "${SSHD_TMP:-}"' EXIT
while IFS= read -r key; do
  key="${key%$'\r'}"
  [[ -n "$key" ]] || continue
  case "$key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *) ;;
    *) die "不支持的 SSH 公钥格式。" ;;
  esac
  KEY_TMP="$(mktemp)"
  printf '%s\n' "$key" >"$KEY_TMP"
  ssh-keygen -lf "$KEY_TMP" >/dev/null 2>&1 || die "SSH 公钥校验失败。"
  grep -Fxq "$key" "$KEYS_TMP" || printf '%s\n' "$key" >>"$KEYS_TMP"
  rm -f "$KEY_TMP"
done <<<"$ADMIN_PUBKEYS"
[[ -s "$KEYS_TMP" ]] || die "没有有效 SSH 公钥。"

SSH_DIR="$REAL_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
backup_path "$SSH_DIR"
if ! is_dry_run; then
  install -d -m 0700 -o "$REAL_USER" -g "$REAL_GROUP" "$SSH_DIR"
fi
replace_marked_block "$AUTHORIZED_KEYS" \
  "# BEGIN vmware-ubuntu-bootstrap keys" "# END vmware-ubuntu-bootstrap keys" \
  0600 "$REAL_USER" "$REAL_GROUP" <"$KEYS_TMP"

PASSWORD_LINES="# Password authentication left unchanged until explicit verification."
if is_true "$DISABLE_SSH_PASSWORD"; then
  is_true "$CONFIRM_SSH_KEY_LOGIN" || die "关闭密码认证前必须确认第二终端公钥登录。"
  PASSWORD_LINES=$'PasswordAuthentication no\nKbdInteractiveAuthentication no'
fi

SSHD_DROPIN="/etc/ssh/sshd_config.d/00-vmware-ubuntu-bootstrap.conf"
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config 未启用 sshd_config.d；拒绝写入不会生效的 drop-in。"
SSHD_TMP="$(mktemp)"
render_template "$VUB_PROJECT_DIR/templates/sshd-local.conf.tpl" \
  "SSH_PORT=$SSH_PORT" "PASSWORD_AUTH_LINES=$PASSWORD_LINES" >"$SSHD_TMP"
write_managed_file "$SSHD_DROPIN" 0644 root root <"$SSHD_TMP"

run "$SSHD_BIN" -t
if ! is_dry_run; then
  SSHD_EFFECTIVE="$($SSHD_BIN -T)"
  grep -Fxq "port $SSH_PORT" <<<"$SSHD_EFFECTIVE" || die "sshd 有效端口不是 $SSH_PORT。"
  grep -Fxq 'permitrootlogin no' <<<"$SSHD_EFFECTIVE" || die "PermitRootLogin=no 未生效。"
  if is_true "$DISABLE_SSH_PASSWORD"; then
    grep -Fxq 'passwordauthentication no' <<<"$SSHD_EFFECTIVE" || die "PasswordAuthentication=no 未生效。"
    grep -Fxq 'kbdinteractiveauthentication no' <<<"$SSHD_EFFECTIVE" || die "KbdInteractiveAuthentication=no 未生效。"
  fi
fi

if is_true "$SSH_SOCKET_MODE"; then
  run systemctl daemon-reload
  run systemctl enable --now ssh.socket
  run systemctl restart ssh.socket
else
  SSH_SERVICE="ssh"
  systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh\.service' || SSH_SERVICE="sshd"
  run systemctl enable --now "$SSH_SERVICE"
  run systemctl reload "$SSH_SERVICE"
fi

if ! is_dry_run; then
  ss -H -ltn | awk -v suffix=":$SSH_PORT" '$4 ~ (suffix "$") {found=1} END {exit !found}' \
    || die "SSH 没有在 tcp/$SSH_PORT 监听。"
fi

UFW_ACTIVE="false"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  UFW_ACTIVE="true"
fi
if is_true "$ENABLE_UFW" || is_true "$UFW_ACTIVE"; then
  require_command ufw
  backup_path /etc/ufw
  run ufw allow from "$PROXY_SCAN_CIDR" to any port "$SSH_PORT" proto tcp comment 'vmware-ubuntu-bootstrap ssh'
  if is_true "$ENABLE_UFW"; then
    run ufw --force enable
  else
    run ufw reload
  fi
  ufw status | grep -Eq "${SSH_PORT}/tcp|${SSH_PORT}[[:space:]]" || die "UFW 未显示 SSH 放行规则。"
fi

complete_backup
mark_phase complete "ssh_port=$SSH_PORT;ufw=$ENABLE_UFW;password_disabled=$DISABLE_SSH_PASSWORD"
TARGET_IP="${STATIC_IPV4_PREFIX}.${STATIC_IPV4_LAST_OCTET}"
info "SSH 配置完成。请从 Windows 验证：ssh -p $SSH_PORT $REAL_USER@$TARGET_IP"
