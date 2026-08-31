#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "backup/rollback: SKIP (requires root)"
  exit 0
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d /tmp/vub-backup-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

export VUB_ETC_DIR="$FIXTURE_ROOT/etc-state"
export VUB_STATE_DIR="$FIXTURE_ROOT/state"
export VUB_LOG_DIR="$FIXTURE_ROOT/log"
export VUB_BACKUP_ROOT="$FIXTURE_ROOT/backups"
export VUB_CONFIG_FILE="$FIXTURE_ROOT/missing-config.env"
export VUB_PHASE_NAME="fixture"
export VUB_YES="true"

# shellcheck source=../scripts/00-lib.sh
source "$ROOT/scripts/00-lib.sh"

TARGET="$FIXTURE_ROOT/managed.conf"
printf 'original\n' >"$TARGET"
start_phase fixture
printf 'changed\n' | replace_marked_block "$TARGET" '# BEGIN fixture' '# END fixture' 0644
printf 'changed-again\n' | replace_marked_block "$TARGET" '# BEGIN fixture' '# END fixture' 0644
complete_backup
SOURCE_BACKUP="$(<"$VUB_STATE_DIR/last-backup")"
[[ "$(grep -Fc '# BEGIN fixture' "$TARGET")" == "1" ]]
grep -Fq 'changed-again' "$TARGET"

bash "$ROOT/scripts/10-rollback.sh" --backup "$SOURCE_BACKUP" --automatic
[[ "$(<"$TARGET")" == "original" ]] || {
  echo "FAIL: rollback did not restore original content" >&2
  exit 1
}

echo "backup/rollback: PASS"
