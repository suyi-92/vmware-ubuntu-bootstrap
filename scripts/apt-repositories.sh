#!/usr/bin/env bash

# This file is sourced by package and validation phases after 00-lib.sh.

VUB_APT_KEYRING_DIR="${VUB_APT_KEYRING_DIR:-/etc/apt/keyrings}"
VUB_APT_SOURCES_DIR="${VUB_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

GITHUB_CLI_KEY="$VUB_APT_KEYRING_DIR/githubcli-archive-keyring.gpg"
GITHUB_CLI_SOURCE="$VUB_APT_SOURCES_DIR/github-cli.list"
GIT_CORE_KEY="$VUB_APT_KEYRING_DIR/git-core-ppa.asc"
GIT_CORE_SOURCE="$VUB_APT_SOURCES_DIR/git-core-ppa.list"
GIT_LFS_KEY="$VUB_APT_KEYRING_DIR/github-git-lfs.asc"
GIT_LFS_SOURCE="$VUB_APT_SOURCES_DIR/github-git-lfs.list"
KITWARE_KEY="$VUB_APT_KEYRING_DIR/kitware-archive.asc"
KITWARE_SOURCE="$VUB_APT_SOURCES_DIR/kitware.list"
DOCKER_KEY="$VUB_APT_KEYRING_DIR/docker.asc"
DOCKER_SOURCE="$VUB_APT_SOURCES_DIR/docker.sources"

# Used by scripts/08-validate.sh after sourcing this file.
# shellcheck disable=SC2034
CORE_UPSTREAM_APT_PATHS=(
  "$GITHUB_CLI_SOURCE" "$GITHUB_CLI_KEY"
  "$GIT_CORE_SOURCE" "$GIT_CORE_KEY"
  "$GIT_LFS_SOURCE" "$GIT_LFS_KEY"
  "$KITWARE_SOURCE" "$KITWARE_KEY"
)
# shellcheck disable=SC2034
DOCKER_APT_PATHS=("$DOCKER_SOURCE" "$DOCKER_KEY")

verify_openpgp_primary_fingerprints() {
  local key_file="$1" label="$2"
  shift 2
  local fingerprint output approved expected gpg_home
  local -a actual_fingerprints=()

  gpg_home="$(mktemp -d "${TMPDIR:-/tmp}/vub-gpg.XXXXXX")"
  chmod 0700 "$gpg_home"
  if ! output="$(
    GNUPGHOME="$gpg_home" \
      gpg --batch --no-options --no-default-keyring --keyring /dev/null \
        --show-keys --with-colons "$key_file" 2>/dev/null \
        | awk -F: '
            $1 == "pub" {want_primary = 1; next}
            want_primary && $1 == "fpr" {print $10; want_primary = 0}
          '
  )"; then
    rm -rf -- "$gpg_home"
    return 1
  fi
  rm -rf -- "$gpg_home"
  mapfile -t actual_fingerprints <<<"$output"
  (( ${#actual_fingerprints[@]} > 0 )) || return 1

  for fingerprint in "${actual_fingerprints[@]}"; do
    [[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]] || return 1
    approved="false"
    for expected in "$@"; do
      if [[ "$fingerprint" == "$expected" ]]; then
        approved="true"
        break
      fi
    done
    if ! is_true "$approved"; then
      warn "$label 密钥包含未批准的主指纹：$fingerprint"
      return 1
    fi
  done
}

install_apt_repository_key() {
  local label="$1" url="$2" target="$3"
  shift 3
  local downloaded

  if is_dry_run; then
    info "DRY-RUN: 下载并校验 $label 密钥：$url -> $target"
    return 0
  fi

  downloaded="$(mktemp)"
  if ! curl -fsSL "$url" -o "$downloaded"; then
    rm -f "$downloaded"
    die "无法下载 $label 密钥：$url"
  fi
  if ! verify_openpgp_primary_fingerprints "$downloaded" "$label" "$@"; then
    rm -f "$downloaded"
    die "$label 密钥指纹校验失败。"
  fi

  if [[ -f "$target" && ! -L "$target" ]] \
      && cmp -s "$downloaded" "$target" \
      && [[ "$(stat -c '%U:%G:%a' "$target")" == "root:root:644" ]]; then
    info "$label 密钥未变化。"
  else
    write_managed_file "$target" 0644 root root <"$downloaded"
  fi
  rm -f "$downloaded"
}

write_apt_source() {
  local path="$1" staged
  staged="$(mktemp)"
  cat >"$staged"
  if [[ -f "$path" && ! -L "$path" ]] \
      && cmp -s "$staged" "$path" \
      && [[ "$(stat -c '%U:%G:%a' "$path")" == "root:root:644" ]]; then
    info "APT 源未变化：$path"
  else
    write_managed_file "$path" 0644 root root <"$staged"
  fi
  rm -f "$staged"
}

configure_upstream_apt_sources() {
  local os_release_file="${VUB_OS_RELEASE_FILE:-/etc/os-release}"
  local architecture codename

  require_command curl
  require_command dpkg
  if ! is_dry_run; then
    require_command gpg
    run install -d -m 0755 -o root -g root "$VUB_APT_KEYRING_DIR" "$VUB_APT_SOURCES_DIR"
  else
    info "DRY-RUN: ensure APT keyring/source directories"
  fi

  [[ -r "$os_release_file" ]] || die "无法读取 $os_release_file"
  # shellcheck disable=SC1090
  source "$os_release_file"
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
    || die "上游 APT 源只支持 Ubuntu 24.04。"
  codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ "$codename" == "noble" ]] || die "Ubuntu 24.04 代号应为 noble，当前：${codename:-unknown}"
  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == "amd64" ]] \
    || die "当前上游软件源配置只支持 amd64，当前：$architecture"

  # Approved primary fingerprints were checked against each publisher on 2026-09-02.
  install_apt_repository_key \
    "GitHub CLI" \
    "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "$GITHUB_CLI_KEY" \
    "2C6106201985B60E6C7AC87323F3D4EA75716059" \
    "7F38BBB59D064DBCB3D84D725612B36462313325"
  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
    "$architecture" "$GITHUB_CLI_KEY" | write_apt_source "$GITHUB_CLI_SOURCE"

  install_apt_repository_key \
    "Git Core PPA" \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xE1DD270288B4E6030699E45FA1715D88E1DF1F24" \
    "$GIT_CORE_KEY" \
    "E1DD270288B4E6030699E45FA1715D88E1DF1F24"
  printf 'deb [arch=%s signed-by=%s] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu %s main\n' \
    "$architecture" "$GIT_CORE_KEY" "$codename" | write_apt_source "$GIT_CORE_SOURCE"

  install_apt_repository_key \
    "Git LFS" \
    "https://packagecloud.io/github/git-lfs/gpgkey" \
    "$GIT_LFS_KEY" \
    "6D398DBD30DD78941E2C4797FE2A5F8BDC282033"
  printf 'deb [arch=%s signed-by=%s] https://packagecloud.io/github/git-lfs/ubuntu/ %s main\n' \
    "$architecture" "$GIT_LFS_KEY" "$codename" | write_apt_source "$GIT_LFS_SOURCE"

  install_apt_repository_key \
    "Kitware" \
    "https://apt.kitware.com/keys/kitware-archive-latest.asc" \
    "$KITWARE_KEY" \
    "4DBEBE3EEC96E7B8C6EC5BE99E92FDC6C5B9BA75"
  printf 'deb [arch=%s signed-by=%s] https://apt.kitware.com/ubuntu/ %s main\n' \
    "$architecture" "$KITWARE_KEY" "$codename" | write_apt_source "$KITWARE_SOURCE"

  if is_true "$INSTALL_DOCKER" && [[ "${DOCKER_SOURCE_KIND:-}" == ce && "${DOCKER_STATE:-}" == absent ]]; then
    install_apt_repository_key \
      "Docker" \
      "https://download.docker.com/linux/ubuntu/gpg" \
      "$DOCKER_KEY" \
      "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    cat <<EOF | write_apt_source "$DOCKER_SOURCE"
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: $DOCKER_KEY
EOF
  fi
  # Existing Docker sources and keys belong to the existing installation. Preserve them.
}

remove_upstream_apt_sources() {
  local path
  # Remove source definitions first so an interruption never leaves a source without its key.
  for path in \
    "$GITHUB_CLI_SOURCE" "$GIT_CORE_SOURCE" "$GIT_LFS_SOURCE" \
    "$KITWARE_SOURCE"; do
    remove_managed_path "$path"
  done
  for path in \
    "$GITHUB_CLI_KEY" "$GIT_CORE_KEY" "$GIT_LFS_KEY" \
    "$KITWARE_KEY"; do
    remove_managed_path "$path"
  done
}
