#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$ROOT" -type f -name '*.sh' -print0)

python3 -m compileall -q "$ROOT/scripts" "$ROOT/tests"
python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
bash "$ROOT/tests/test_input_validation.sh"
bash "$ROOT/tests/test_backup_rollback.sh"
bash "$ROOT/tests/test_status_read_only.sh"
bash "$ROOT/tests/test_preflight_dry_run.sh"
bash "$ROOT/install.sh" --help >/dev/null
bash "$ROOT/bootstrap.sh" --help >/dev/null

if command -v shellcheck >/dev/null 2>&1; then
  mapfile -d '' shell_files < <(find "$ROOT" -type f -name '*.sh' -print0)
  shellcheck -x -S warning -e SC1091 "${shell_files[@]}"
else
  echo "shellcheck: SKIP (not installed)"
fi

echo "all tests: PASS"
