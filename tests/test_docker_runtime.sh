#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../scripts/00-lib.sh
source "$ROOT/scripts/00-lib.sh"
# Runtime activation has changed from unconditional restart to reuse/start only.
# test_docker_local.py covers the lower command boundary and package effects.
docker_detect() { printf '%s\n' "$TEST_STATE"; }
docker_local_healthy() { return 0; }
docker_start_existing() { printf 'start existing\n'; return "${TEST_START_CODE:-0}"; }
TEST_STATE=healthy-ce
OUTPUT=$(activate_docker_runtime)
[[ "$OUTPUT" == *'复用现有 Docker'* && "$OUTPUT" != *'start existing'* ]]
TEST_STATE=stopped-distro
OUTPUT=$(activate_docker_runtime)
[[ "$OUTPUT" == *'start existing'* ]]
TEST_START_CODE=1
if (activate_docker_runtime >/dev/null 2>&1); then exit 1; fi
TEST_STATE=broken
if (activate_docker_runtime >/dev/null 2>&1); then exit 1; fi
echo 'docker runtime: PASS'
