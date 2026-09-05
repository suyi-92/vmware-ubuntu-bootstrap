#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vub-dependency-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT
mkdir -p "$FIXTURE_ROOT/bin"

APT_LOG="$FIXTURE_ROOT/apt.log"
export APT_LOG

cat >"$FIXTURE_ROOT/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
package="${!#}"
if [[ "$package" == "curl" ]]; then
  exit 1
fi
if [[ "$package" == "ca-certificates" ]]; then
  printf 'hold ok installed\n'
  exit 0
fi
printf 'install ok installed\n'
EOF

cat >"$FIXTURE_ROOT/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_LOG"
EOF
chmod +x "$FIXTURE_ROOT/bin/dpkg-query" "$FIXTURE_ROOT/bin/apt-get"

export PATH="$FIXTURE_ROOT/bin:$PATH"
export VUB_DRY_RUN=false
export VUB_LOG_FILE=""
# shellcheck source=../scripts/00-lib.sh
source "$ROOT/scripts/00-lib.sh"

install_missing_apt_packages "测试依赖安装" git curl ca-certificates
upgrade_installed_apt_packages
install_or_upgrade_apt_packages "测试升级安装" gh git-lfs

grep -Fxq 'update' "$APT_LOG"
grep -Fq 'install -y --no-remove --no-install-recommends curl' "$APT_LOG"
if grep -Eq '^install .* (git|ca-certificates)( |$)' "$APT_LOG"; then
  echo "FAIL: 已安装的软件包被重复传给 apt-get" >&2
  exit 1
fi
grep -Fxq 'upgrade -y --with-new-pkgs --no-remove' "$APT_LOG"
grep -Fq -- '--simulate --no-remove install --no-install-recommends gh git-lfs' "$APT_LOG"
grep -Fq 'install -y --no-remove --no-install-recommends gh git-lfs' "$APT_LOG"

echo "dependency install: PASS"
