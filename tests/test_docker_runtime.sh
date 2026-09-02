#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-docker-runtime.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

MOCK_BIN="$FIXTURE_ROOT/bin"
COMMAND_LOG="$FIXTURE_ROOT/commands.log"
mkdir -p "$MOCK_BIN"
: >"$COMMAND_LOG"

cat >"$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'systemctl %s\n' "$*" >>"$VUB_TEST_COMMAND_LOG"
if [[ "$*" == "restart docker.service" && "${VUB_FAIL_DOCKER_RESTART:-false}" == "true" ]]; then
  exit 1
fi
case "$*" in
  "is-enabled --quiet docker.socket"|"is-active --quiet docker.socket"|\
  "is-enabled --quiet docker.service"|"is-active --quiet docker.service") exit 0 ;;
esac
exit 0
EOF

cat >"$MOCK_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'docker %s\n' "$*" >>"$VUB_TEST_COMMAND_LOG"
[[ "$*" == "info" ]]
EOF
chmod +x "$MOCK_BIN/systemctl" "$MOCK_BIN/docker"

export PATH="$MOCK_BIN:/usr/bin:/bin"
export VUB_TEST_COMMAND_LOG="$COMMAND_LOG"
export VUB_DRY_RUN=false
export VUB_TESTING=true
# shellcheck source=../scripts/00-lib.sh
source "$ROOT/scripts/00-lib.sh"

activate_docker_runtime >/dev/null
cat >"$FIXTURE_ROOT/expected.log" <<'EOF'
systemctl daemon-reload
systemctl reset-failed docker.service docker.socket
systemctl enable docker.socket docker.service
systemctl start docker.socket
systemctl restart docker.service
systemctl is-enabled --quiet docker.socket
systemctl is-active --quiet docker.socket
systemctl is-enabled --quiet docker.service
systemctl is-active --quiet docker.service
docker info
EOF
diff -u "$FIXTURE_ROOT/expected.log" "$COMMAND_LOG" \
  || fail "Docker runtime activation order is incorrect"

: >"$COMMAND_LOG"
if (
  export VUB_FAIL_DOCKER_RESTART=true
  activate_docker_runtime
) >"$FIXTURE_ROOT/failure.out" 2>&1; then
  fail "Docker service restart failure was accepted"
fi
grep -Fq 'Docker service 启动失败' "$FIXTURE_ROOT/failure.out" \
  || fail "Docker restart failure did not report the cause"
if grep -Fq 'docker info' "$COMMAND_LOG"; then
  fail "Docker verification continued after restart failure"
fi

echo "docker runtime: PASS"
