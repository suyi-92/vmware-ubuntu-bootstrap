#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC2034

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VUB_TESTING=true
export VUB_TESTING
# shellcheck source=../scripts/00-lib.sh
source "$ROOT/scripts/00-lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

validate_cpa_url "https://cpa.example.com/v1" >/dev/null
validate_cpa_url "http://192.168.1.100:8317/v1" >/dev/null
validate_cpa_url "http://cpa.local/v1" >/dev/null

if (validate_cpa_url "http://example.com/v1" >/dev/null 2>&1); then
  fail "public HTTP CPA URL was accepted"
fi
if (validate_cpa_url "https://cpa.example.com/v1?x=1" >/dev/null 2>&1); then
  fail "CPA URL with query was accepted"
fi

CONFIGURE_CODEX=false
CONFIGURE_STATIC_NETWORK=true
ENABLE_UFW=false
DISABLE_SSH_PASSWORD=false
CONFIRM_SSH_KEY_LOGIN=false
CPA_BYPASS_PROXY=false
RUN_CPA_SMOKE=false
RUN_CODEX_SMOKE=false
ENABLE_UPSTREAM_APT_SOURCES=false
UPGRADE_INSTALLED_PACKAGES=false
INSTALL_DOCKER=false
ENABLE_PASSWORDLESS_SUDO=true
STATIC_IPV4_PREFIX="192.168.1"
STATIC_IPV4_LAST_OCTET="254"
PREFIX_LENGTH="24"
PROXY_PORT="7890"
SSH_PORT="22"
NETWORK_INTERFACE="ens33"
HOSTNAME="a"
export CONFIGURE_CODEX CONFIGURE_STATIC_NETWORK
export ENABLE_UFW DISABLE_SSH_PASSWORD CONFIRM_SSH_KEY_LOGIN
export CPA_BYPASS_PROXY
export RUN_CPA_SMOKE RUN_CODEX_SMOKE
export ENABLE_UPSTREAM_APT_SOURCES UPGRADE_INSTALLED_PACKAGES
export INSTALL_DOCKER ENABLE_PASSWORDLESS_SUDO
export STATIC_IPV4_PREFIX STATIC_IPV4_LAST_OCTET PREFIX_LENGTH
export PROXY_PORT SSH_PORT NETWORK_INTERFACE HOSTNAME
validate_config

STATIC_IPV4_LAST_OCTET="255"
if (validate_config >/dev/null 2>&1); then
  fail "broadcast address suffix was accepted"
fi

STATIC_IPV4_LAST_OCTET="254"
NETWORK_INTERFACE='ens33: bad'
if (validate_config >/dev/null 2>&1); then
  fail "unsafe interface name was accepted"
fi

validate_sudoers_username "suyi" || fail "normal sudoers username was rejected"
if validate_sudoers_username 'bad user'; then
  fail "unsafe sudoers username was accepted"
fi

if command -v visudo >/dev/null 2>&1; then
  SUDOERS_FIXTURE="$(mktemp)"
  render_passwordless_sudoers "suyi" >"$SUDOERS_FIXTURE"
  visudo -cf "$SUDOERS_FIXTURE" >/dev/null \
    || fail "rendered passwordless sudoers rule is invalid"
  grep -Fxq 'suyi ALL=(ALL:ALL) NOPASSWD: ALL' "$SUDOERS_FIXTURE" \
    || fail "rendered passwordless sudoers rule is incomplete"
  rm -f "$SUDOERS_FIXTURE"
fi

SOCKET_RENDERED="$(render_template "$ROOT/templates/ssh-socket.conf.tpl" "SSH_PORT=2222")"
grep -Fxq 'ListenStream=' <<<"$SOCKET_RENDERED" \
  || fail "SSH socket template does not reset the vendor listener"
grep -Fxq 'ListenStream=0.0.0.0:2222' <<<"$SOCKET_RENDERED" \
  || fail "SSH socket template does not apply the IPv4 listener"
grep -Fxq 'ListenStream=[::]:2222' <<<"$SOCKET_RENDERED" \
  || fail "SSH socket template does not apply the IPv6 listener"
grep -Fxq 'BindIPv6Only=ipv6-only' <<<"$SOCKET_RENDERED" \
  || fail "SSH socket template does not isolate the explicit IPv6 listener"

echo "input validation: PASS"
