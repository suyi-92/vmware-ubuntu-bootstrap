#!/usr/bin/env bash
# Opt-in diagnostics for the network refresh call chain. Never print commands,
# arguments, variable values or config contents: they may contain credentials.
shopt -s inherit_errexit
VUB_FAILURE_STAGE=initialization
vub_exit_status=0

vub_stage() {
  VUB_FAILURE_STAGE="$1"
  printf '[INFO] 阶段：%s\n' "$VUB_FAILURE_STAGE" >&2
}

vub_failure() {
  local status="$1" file="$2" line="$3" frame
  trap - ERR EXIT
  set +e
  printf '[ERROR] 失败阶段=%s；位置=%s:%s；退出码=%s\n' \
    "$VUB_FAILURE_STAGE" "$file" "$line" "$status" >&2
  for ((frame=1; frame<${#FUNCNAME[@]}; frame++)); do
    # Bash reports LINENO=1 inside EXIT traps. Do not present that synthetic
    # line as the failing instruction; the remaining frames are call sites.
    if [[ "$line" == EXIT && "$frame" == 1 ]]; then continue; fi
    printf '  调用：%s (%s:%s)\n' "${FUNCNAME[frame]}" \
      "${BASH_SOURCE[frame]}" "${BASH_LINENO[frame-1]}" >&2
  done
  exit "$status"
}

# ERR locates unexpected failures; EXIT also catches explicit exit/die and
# nounset errors, which do not necessarily trigger ERR. Capture $? first.
trap 'vub_failure "$?" "${BASH_SOURCE[0]}" "$LINENO"' ERR
trap 'vub_exit_status=$?; if (( vub_exit_status != 0 )); then vub_failure "$vub_exit_status" "${BASH_SOURCE[0]}" EXIT; fi' EXIT
