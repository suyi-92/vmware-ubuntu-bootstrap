#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=00-lib.sh
source "$SCRIPT_DIR/00-lib.sh"

start_phase "input-method"
require_root
load_config true
resolve_real_user
validate_config

if ! is_true "$CONFIGURE_FCITX5_RIME"; then
  mark_phase skipped "disabled by config"
  info "按配置跳过 Fcitx5/Rime。"
  exit 0
fi

load_proxy_state || warn "尚无持久化代理状态；Plum 将使用当前环境或直连。"

RIME_DIR="${VUB_RIME_DIR:-$REAL_HOME/.local/share/fcitx5/rime}"
RIME_BUILD_DIR="$RIME_DIR/build"
RIME_SHARED_DIR="${VUB_RIME_SHARED_DIR:-/usr/share/rime-data}"
PLUM_DIR="${VUB_PLUM_DIR:-$REAL_HOME/plum}"
FCITX5_CONFIG_DIR="${VUB_FCITX5_CONFIG_DIR:-$REAL_HOME/.config/fcitx5}"
FCITX5_PROFILE="${VUB_FCITX5_PROFILE:-$FCITX5_CONFIG_DIR/profile}"
FCITX5_GLOBAL_CONFIG="${VUB_FCITX5_GLOBAL_CONFIG:-$FCITX5_CONFIG_DIR/config}"
XINPUTRC="${VUB_XINPUTRC:-$REAL_HOME/.xinputrc}"
RIME_CUSTOM="$RIME_DIR/default.custom.yaml"
RIME_SCHEMA="$RIME_DIR/rime_ice.schema.yaml"
RIME_COMPILED="$RIME_BUILD_DIR/default.yaml"
PLUM_REPOSITORY="https://github.com/rime/plum.git"
RIME_ICE_CACHE_DIR="$PLUM_DIR/package/iDvel/ice"
RIME_ICE_REPOSITORY="https://github.com/iDvel/rime-ice.git"

FCITX5_RIME_PACKAGES=(
  fcitx5 fcitx5-rime fcitx5-config-qt
  fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5
  librime-plugin-lua librime-plugin-octagram librime-bin im-config git
)

validate_user_managed_path() {
  local path="$1" normalized
  if is_true "$VUB_TESTING"; then
    return 0
  fi
  normalized="$(realpath -m -- "$path")"
  [[ "$normalized" == "$REAL_HOME/"* ]] \
    || die "输入法用户路径不在 $REAL_HOME 内：$path"
}

validate_existing_user_file() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  [[ -f "$path" && ! -L "$path" ]] || die "输入法配置不是普通文件：$path"
  [[ "$(stat -c %U "$path")" == "$REAL_USER" ]] \
    || die "输入法配置不属于 $REAL_USER：$path"
}

prepare_user_directory() {
  local path="$1"
  if is_dry_run; then
    info "DRY-RUN as $REAL_USER: mkdir -p $(shell_join "$path")"
    return 0
  fi
  run_as_user mkdir -p -- "$path"
  [[ -d "$path" && ! -L "$path" ]] || die "输入法目录不安全：$path"
  [[ "$(stat -c %U "$path")" == "$REAL_USER" ]] \
    || die "输入法目录不属于 $REAL_USER：$path"
}

stop_running_fcitx5() {
  local attempt
  if is_dry_run; then
    info "DRY-RUN: stop the running Fcitx5 user daemon before changing its profile"
    return 0
  fi
  pgrep -u "$REAL_UID" -x fcitx5 >/dev/null 2>&1 || return 0

  warn "检测到正在运行的 Fcitx5；先安全退出，防止旧进程覆盖新配置。"
  if [[ -S "/run/user/${REAL_UID}/bus" ]] \
      && run_as_user_with_bus fcitx5-remote --check >/dev/null 2>&1; then
    run_as_user_with_bus fcitx5-remote -e >/dev/null 2>&1 || true
  fi
  if pgrep -u "$REAL_UID" -x fcitx5 >/dev/null 2>&1; then
    run_as_user pkill -TERM -x fcitx5
  fi
  for ((attempt = 0; attempt < 25; attempt++)); do
    pgrep -u "$REAL_UID" -x fcitx5 >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  die "Fcitx5 未能安全退出；拒绝在运行中覆盖 profile。"
}

validate_github_worktree() {
  local path="$1" repository="$2" label="$3" origin repository_without_suffix
  local github_path="${repository#https://github.com/}"
  repository_without_suffix="${repository%.git}"
  [[ -d "$path" && ! -L "$path" ]] || die "$label 路径不是安全目录：$path"
  [[ "$(stat -c %U "$path")" == "$REAL_USER" ]] || die "$label 目录不属于 $REAL_USER。"
  run_as_user git -C "$path" rev-parse --is-inside-work-tree \
    | grep -Fxq true || die "$label 目录不是 Git 工作树：$path"
  origin="$(run_as_user git -C "$path" remote get-url origin)"
  case "$origin" in
    "$repository"|"$repository_without_suffix") ;;
    "git@github.com:${github_path}"|"ssh://git@github.com/${github_path}")
      run_as_user git -C "$path" remote set-url origin "$repository"
      info "已将 $label origin 切换为 GitHub HTTPS。"
      ;;
    *) die "$label origin 不是 ${github_path%.git}：$origin" ;;
  esac
  [[ -z "$(run_as_user git -C "$path" status --porcelain)" ]] \
    || die "$label 工作树存在本地改动；请先处理后重试：$path"
}

update_github_worktree_ff() {
  local path="$1" label="$2" branch local_head remote_head
  branch="$(run_as_user git -C "$path" symbolic-ref --quiet --short HEAD)" \
    || die "$label 未处于本地分支，无法安全更新。"
  run_logged "更新 $label" run_as_user env GIT_TERMINAL_PROMPT=0 \
    git -C "$path" pull --ff-only origin "$branch"
  local_head="$(run_as_user git -C "$path" rev-parse HEAD)"
  remote_head="$(run_as_user git -C "$path" rev-parse "refs/remotes/origin/$branch")"
  [[ "$local_head" == "$remote_head" ]] \
    || die "$label 含有未发布到 origin/$branch 的本地提交；拒绝执行远程脚本。"
}

if ! is_dry_run; then
  for package in "${FCITX5_RIME_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null \
      | grep -Fxq 'install ok installed' \
      || die "Fcitx5/Rime 软件包未安装：$package；请先运行 packages 阶段。"
  done
  for command_name in git im-config fcitx5 fcitx5-remote rime_deployer pgrep pkill; do
    require_command "$command_name"
  done
  [[ -d "$RIME_SHARED_DIR" ]] || die "Rime 系统数据目录不存在：$RIME_SHARED_DIR"
else
  info "DRY-RUN: verify Fcitx5, Rime, Lua/Octagram, im-config and librime tools"
fi

for user_path in "$RIME_DIR" "$PLUM_DIR" "$FCITX5_CONFIG_DIR" \
  "$FCITX5_PROFILE" "$FCITX5_GLOBAL_CONFIG" "$XINPUTRC"; do
  validate_user_managed_path "$user_path"
done
validate_existing_user_file "$FCITX5_PROFILE"
validate_existing_user_file "$FCITX5_GLOBAL_CONFIG"
validate_existing_user_file "$XINPUTRC"

if [[ -e "$PLUM_DIR" || -L "$PLUM_DIR" ]]; then
  if ! is_dry_run; then
    validate_github_worktree "$PLUM_DIR" "$PLUM_REPOSITORY" "Plum"
  fi
fi

stop_running_fcitx5

# Rime 数据、Fcitx 配置和 im-config 选择均在修改前进入项目回滚快照。
backup_path "$RIME_DIR"
backup_path "$FCITX5_PROFILE"
backup_path "$FCITX5_GLOBAL_CONFIG"
backup_path "$XINPUTRC"

prepare_user_directory "$RIME_DIR"
prepare_user_directory "$FCITX5_CONFIG_DIR"

if ! is_dry_run; then
  FIRST_RIME_ENTRY="$(find "$RIME_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
  if [[ -n "$FIRST_RIME_ENTRY" && ! -f "$RIME_SCHEMA" ]]; then
    RIME_BACKUP_BASE="${RIME_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
    RIME_BACKUP="$RIME_BACKUP_BASE"
    RIME_BACKUP_INDEX=0
    while [[ -e "$RIME_BACKUP" || -L "$RIME_BACKUP" ]]; do
      RIME_BACKUP_INDEX=$((RIME_BACKUP_INDEX + 1))
      RIME_BACKUP="${RIME_BACKUP_BASE}.${RIME_BACKUP_INDEX}"
    done
    backup_path "$RIME_BACKUP"
    run_as_user cp -a -- "$RIME_DIR" "$RIME_BACKUP"
    run_as_user find "$RIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    info "首次安装前的 Rime 配置已备份到：$RIME_BACKUP"
  elif [[ -f "$RIME_SCHEMA" ]]; then
    info "检测到现有雾凇拼音；保留用户词库并执行可重复更新。"
  fi
else
  info "DRY-RUN: back up and clear a non-empty initial Rime directory when rime_ice is absent"
fi

run_as_user im-config -n fcitx5

if [[ -e "$PLUM_DIR/.git" || -L "$PLUM_DIR/.git" ]]; then
  if is_dry_run; then
    run_logged "更新 Plum" run_as_user env GIT_TERMINAL_PROMPT=0 \
      git -C "$PLUM_DIR" pull --ff-only
  else
    update_github_worktree_ff "$PLUM_DIR" "Plum"
  fi
else
  run_logged "通过 GitHub HTTPS 安装 Plum" run_as_user env GIT_TERMINAL_PROMPT=0 \
    git clone "$PLUM_REPOSITORY" "$PLUM_DIR"
fi

if ! is_dry_run; then
  validate_github_worktree "$PLUM_DIR" "$PLUM_REPOSITORY" "Plum"
  if [[ -e "$RIME_ICE_CACHE_DIR" || -L "$RIME_ICE_CACHE_DIR" ]]; then
    validate_github_worktree \
      "$RIME_ICE_CACHE_DIR" "$RIME_ICE_REPOSITORY" "雾凇拼音缓存"
    update_github_worktree_ff "$RIME_ICE_CACHE_DIR" "雾凇拼音缓存"
  fi
fi

run_logged "安装或更新雾凇拼音" run_as_user env \
  GIT_TERMINAL_PROMPT=0 no_update=1 \
  rime_frontend=fcitx5-rime rime_dir="$RIME_DIR" \
  bash "$PLUM_DIR/rime-install" iDvel/rime-ice

if ! is_dry_run; then
  [[ -f "$RIME_SCHEMA" ]] || die "Plum 完成后仍找不到雾凇拼音 schema：$RIME_SCHEMA"
fi

render_template "$VUB_PROJECT_DIR/templates/rime-default.custom.yaml.tpl" \
  | write_user_file "$RIME_CUSTOM" 0644
render_template "$VUB_PROJECT_DIR/templates/fcitx5-profile.conf.tpl" \
  | write_user_file "$FCITX5_PROFILE" 0644

FCITX5_GLOBAL_TMP="$(mktemp)"
trap 'rm -f "${FCITX5_GLOBAL_TMP:-}"' EXIT
python3 "$SCRIPT_DIR/fcitx5_rime_config.py" render-global \
  --input "$FCITX5_GLOBAL_CONFIG" >"$FCITX5_GLOBAL_TMP"
write_user_file "$FCITX5_GLOBAL_CONFIG" 0644 <"$FCITX5_GLOBAL_TMP"
rm -f "$FCITX5_GLOBAL_TMP"
FCITX5_GLOBAL_TMP=""

run_as_user rm -rf -- "$RIME_BUILD_DIR"
run_logged "编译雾凇拼音配置" run_as_user rime_deployer --build \
  "$RIME_DIR" "$RIME_SHARED_DIR" "$RIME_BUILD_DIR"

if ! is_dry_run; then
  grep -Fxq 'run_im fcitx5' "$XINPUTRC" || die "im-config 未将 Fcitx5 设为输入法框架。"
  for user_file in "$FCITX5_PROFILE" "$FCITX5_GLOBAL_CONFIG" "$RIME_CUSTOM" "$RIME_COMPILED"; do
    [[ -f "$user_file" && ! -L "$user_file" ]] || die "输入法配置文件不存在或不安全：$user_file"
    [[ "$(stat -c %U "$user_file")" == "$REAL_USER" ]] \
      || die "输入法配置文件不属于 $REAL_USER：$user_file"
  done
  python3 "$SCRIPT_DIR/fcitx5_rime_config.py" validate \
    --profile "$FCITX5_PROFILE" \
    --global-config "$FCITX5_GLOBAL_CONFIG" \
    --custom "$RIME_CUSTOM" \
    --compiled "$RIME_COMPILED" \
    || die "Fcitx5/Rime 编译结果验收失败。"
fi

complete_backup
mark_phase complete \
  "framework=fcitx5;default_im=rime;active_by_default=true;schema=rime_ice;page_size=9"
info "Fcitx5 + Rime + 雾凇拼音配置完成。请注销 Ubuntu 并重新登录后使用。"
