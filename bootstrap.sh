#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/00-lib.sh
source "$PROJECT_DIR/scripts/00-lib.sh"

PHASE=""
ROLLBACK_ID=""

usage() {
  cat <<'EOF'
用法：
  sudo bash bootstrap.sh --phase <phase> [--config config.env] [--dry-run] [--yes] [--verbose]

阶段：
  full, preflight, proxy, proxy-status, proxy-off, packages,
  static-network, power, ssh, codex, validate, status, rollback
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --phase) PHASE="${2:-}"; shift 2 ;;
    --config) VUB_CONFIG_FILE="${2:-}"; shift 2 ;;
    --dry-run) VUB_DRY_RUN="true"; shift ;;
    --yes|-y) VUB_YES="true"; shift ;;
    --verbose) VUB_VERBOSE="true"; shift ;;
    --backup) ROLLBACK_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$PHASE" ]] || { usage >&2; exit 2; }
if [[ "$VUB_CONFIG_FILE" != /* ]]; then
  VUB_CONFIG_FILE="$(cd -- "$(dirname -- "$VUB_CONFIG_FILE")" && pwd -P)/$(basename -- "$VUB_CONFIG_FILE")"
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  sudo_args=(--phase "$PHASE" --config "$VUB_CONFIG_FILE")
  is_true "$VUB_DRY_RUN" && sudo_args+=(--dry-run)
  is_true "$VUB_YES" && sudo_args+=(--yes)
  is_true "$VUB_VERBOSE" && sudo_args+=(--verbose)
  [[ -n "$ROLLBACK_ID" ]] && sudo_args+=(--backup "$ROLLBACK_ID")
  exec sudo -E bash "$0" "${sudo_args[@]}"
fi

export VUB_CONFIG_FILE VUB_DRY_RUN VUB_YES VUB_VERBOSE

phase_script() {
  case "$1" in
    preflight) printf '%s\n' "$PROJECT_DIR/scripts/01-preflight.sh" ;;
    proxy|proxy-status|proxy-off) printf '%s\n' "$PROJECT_DIR/scripts/02-proxy.sh" ;;
    packages) printf '%s\n' "$PROJECT_DIR/scripts/03-packages.sh" ;;
    static-network) printf '%s\n' "$PROJECT_DIR/scripts/04-static-network.sh" ;;
    power) printf '%s\n' "$PROJECT_DIR/scripts/05-power-policy.sh" ;;
    ssh) printf '%s\n' "$PROJECT_DIR/scripts/06-ssh.sh" ;;
    codex) printf '%s\n' "$PROJECT_DIR/scripts/07-codex.sh" ;;
    validate) printf '%s\n' "$PROJECT_DIR/scripts/08-validate.sh" ;;
    status) printf '%s\n' "$PROJECT_DIR/scripts/09-status.sh" ;;
    rollback) printf '%s\n' "$PROJECT_DIR/scripts/10-rollback.sh" ;;
    *) return 1 ;;
  esac
}

run_one_phase() {
  local phase="$1" script action=""
  script="$(phase_script "$phase")" || die "未知阶段：$phase"
  case "$phase" in
    proxy) action="apply" ;;
    proxy-status) action="status" ;;
    proxy-off) action="off" ;;
  esac

  info "执行阶段：$phase"
  if [[ "$phase" == "rollback" ]]; then
    rollback_args=()
    [[ -n "$ROLLBACK_ID" ]] && rollback_args+=(--backup "$ROLLBACK_ID")
    VUB_PHASE_NAME="$phase" bash "$script" "${rollback_args[@]}"
  elif [[ -n "$action" ]]; then
    VUB_PHASE_NAME="$phase" bash "$script" "$action"
  else
    VUB_PHASE_NAME="$phase" bash "$script"
  fi
}

handle_phase_failure() {
  local phase="$1"
  warn "阶段失败：$phase"
  VUB_PHASE_NAME="$phase"
  export VUB_PHASE_NAME
  mark_phase failed "phase command failed" || true
  case "$phase" in
    proxy|proxy-off|packages|static-network|power|ssh|codex)
      if [[ -r "$VUB_STATE_DIR/active-backup" && -f "$PROJECT_DIR/scripts/10-rollback.sh" ]]; then
        local active
        active="$(<"$VUB_STATE_DIR/active-backup")"
        warn "尝试回滚当前阶段备份：$active"
        VUB_PHASE_NAME="rollback" bash "$PROJECT_DIR/scripts/10-rollback.sh" --backup "$active" --automatic || \
          warn "自动回滚未完整成功，请按 recovery 文档处理。"
      fi
      ;;
  esac
}

run_full() {
  local phase
  for phase in preflight proxy packages static-network power ssh codex validate; do
    if ! run_one_phase "$phase"; then
      handle_phase_failure "$phase"
      return 1
    fi
  done
}

case "$PHASE" in
  full) run_full ;;
  preflight|proxy|proxy-status|proxy-off|packages|static-network|power|ssh|codex|validate|status|rollback)
    if ! run_one_phase "$PHASE"; then
      handle_phase_failure "$PHASE"
      exit 1
    fi
    ;;
  *) die "未知阶段：$PHASE" ;;
esac
