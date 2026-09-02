#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"
# shellcheck source=apt-repositories.sh
source "$SCRIPT_DIR/apt-repositories.sh"

require_root
load_config false
resolve_real_user

echo "=== VMware Ubuntu Bootstrap ==="
echo "project: $VUB_PROJECT_DIR"
echo "user:    $REAL_USER"
echo

echo "=== Phase states ==="
if [[ -d "$VUB_STATE_DIR" ]]; then
  shopt -s nullglob
  states=("$VUB_STATE_DIR"/*.state)
  if (( ${#states[@]} == 0 )); then
    echo "(none)"
  else
    for state in "${states[@]}"; do
      phase="$(basename "$state" .state)"
      status="$(sed -nE 's/^status=(.*)$/\1/p' "$state" | head -n1)"
      printf '%-20s %s\n' "$phase" "${status:-unknown}"
    done
  fi
  shopt -u nullglob
else
  echo "(none)"
fi
echo

echo "=== Network ==="
iface="${NETWORK_INTERFACE:-$(current_interface)}"
echo "interface: ${iface:-unknown}"
echo "IPv4:     $(current_ipv4 "$iface" 2>/dev/null || echo unknown)"
echo "gateway:  $(current_gateway 2>/dev/null || echo unknown)"
if [[ -r "$VUB_CONFIG_FILE" ]] && is_true "$CONFIGURE_STATIC_NETWORK"; then
  static_status="$(sed -nE 's/^status=(.*)$/\1/p' "$VUB_STATE_DIR/static-network.state" 2>/dev/null | head -n1 || true)"
  echo "target:   ${STATIC_IPV4_PREFIX}.${STATIC_IPV4_LAST_OCTET}/${PREFIX_LENGTH}"
  if [[ "$static_status" == "pending-reboot" ]]; then
    echo "switch:   after reboot"
  else
    echo "switch:   ${static_status:-not configured}"
  fi
fi
echo

echo "=== Proxy ==="
if load_proxy_state; then
  echo "proxy:    ${http_proxy:-未配置}"
  echo "all_proxy: ${all_proxy:-未配置}"
  echo "no_proxy: ${no_proxy:-未配置}"
else
  echo "(not managed)"
fi
echo

echo "=== Services ==="
for unit in open-vm-tools.service ssh.socket ssh.service sshd.service docker.socket docker.service; do
  if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^${unit}"; then
    printf '%-24s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
  fi
done
echo

echo "=== APT / developer tools ==="
if [[ -f "$GITHUB_CLI_SOURCE" && -f "$GIT_CORE_SOURCE" \
    && -f "$GIT_LFS_SOURCE" && -f "$KITWARE_SOURCE" ]]; then
  echo "upstream sources: configured"
else
  echo "upstream sources: incomplete or disabled"
fi
printf '%-12s %s\n' git "$(git --version 2>/dev/null || echo missing)"
printf '%-12s %s\n' gh "$(gh --version 2>/dev/null | head -n1 || echo missing)"
printf '%-12s %s\n' git-lfs "$(git lfs version 2>/dev/null || echo missing)"
printf '%-12s %s\n' cmake "$(cmake --version 2>/dev/null | head -n1 || echo missing)"
upgradable_count="$(apt list --upgradable 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d' | wc -l)"
echo "APT upgrades: ${upgradable_count:-unknown}"
echo

echo "=== VMware clipboard ==="
for vmware_package in open-vm-tools open-vm-tools-desktop; do
  if dpkg-query -W -f='${Status}\n' "$vmware_package" 2>/dev/null \
    | grep -Fxq 'install ok installed'; then
    printf '%-24s %s\n' "$vmware_package" "installed"
  else
    printf '%-24s %s\n' "$vmware_package" "missing"
  fi
done
if [[ -r /etc/xdg/autostart/vmware-user.desktop ]]; then
  echo "desktop autostart:       present"
else
  echo "desktop autostart:       missing"
fi
desktop_agent_status="not running (log in to the graphical desktop)"
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -a -u "$REAL_UID" -x vmtoolsd 2>/dev/null \
      | grep -Eq '[[:space:]]-n[[:space:]]+vmusr([[:space:]]|$)' \
    || pgrep -u "$REAL_UID" -f '(^|/)(vmware-user|vmware-user-suid-wrapper)([[:space:]]|$)' >/dev/null; then
    desktop_agent_status="running"
  fi
fi
echo "desktop agent:           $desktop_agent_status"
echo

echo "=== Power ==="
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  printf '%-24s %s\n' "$target" "$(systemctl is-enabled "$target" 2>/dev/null || true)"
done
echo

echo "=== SSH ==="
echo "port: ${SSH_PORT:-22}"
[[ -f "$REAL_HOME/.ssh/authorized_keys" ]] && echo "authorized_keys: present" || echo "authorized_keys: missing"
echo

echo "=== sudo policy ==="
passwordless_file="${VUB_PASSWORDLESS_SUDOERS_FILE:-/etc/sudoers.d/90-vmware-ubuntu-bootstrap-passwordless}"
if [[ -f "$passwordless_file" ]]; then
  echo "passwordless sudo: enabled ($(stat -c '%U:%G:%a' "$passwordless_file" 2>/dev/null || echo invalid))"
else
  echo "passwordless sudo: disabled"
fi
echo

echo "=== Codex / CPA ==="
codex_bin="$REAL_HOME/.local/bin/codex"
[[ -x "$codex_bin" ]] || codex_bin="$REAL_HOME/.codex/bin/codex"
if [[ -x "$codex_bin" && -s "$REAL_HOME/.codex/config.toml" ]]; then
  echo "command:  codex"
  echo "binary:   $codex_bin"
  echo "config:   $REAL_HOME/.codex/config.toml"
  if command -v bwrap >/dev/null 2>&1 && [[ -f /etc/apparmor.d/bwrap-userns-restrict ]]; then
    echo "sandbox:  bubblewrap/AppArmor configured"
  else
    echo "sandbox:  incomplete"
  fi
  key_file="$REAL_HOME/.config/vmware-ubuntu-bootstrap/secrets/cpa-api-key"
  [[ -f "$key_file" ]] && echo "key:     present ($(stat -c '%U:%G:%a' "$key_file"))" || echo "key:     missing"
else
  echo "(not configured)"
fi
echo

if [[ -f "$VUB_STATE_DIR/reboot-required" ]]; then
  echo "reboot: required"
else
  echo "reboot: not pending"
fi
