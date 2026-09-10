#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if os.geteuid() != 0:
    print('refresh recovery: SKIP (Linux root fixture required)')
    raise SystemExit(0)

project = Path(sys.argv[1])
library = r'''#!/usr/bin/env bash
VUB_CONFIG_FILE="$FIXTURE/config.env"
VUB_STATE_DIR="$FIXTURE/state"
VUB_BACKUP_ROOT="$FIXTURE/backups"
VUB_ETC_DIR="$FIXTURE/etc"
VUB_DRY_RUN="${VUB_DRY_RUN:-false}"
VUB_YES=true
VUB_VERBOSE=false
export VUB_CONFIG_FILE VUB_STATE_DIR VUB_BACKUP_ROOT VUB_ETC_DIR VUB_DRY_RUN VUB_YES VUB_VERBOSE
info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
is_true() { [[ "$1" == true ]]; }
is_dry_run() { is_true "$VUB_DRY_RUN"; }
require_root() { :; }
require_command() { command -v "$1" >/dev/null || die "missing $1"; }
load_config() { :; }
resolve_real_user() { :; }
mark_phase() { :; }
start_phase() { VUB_PHASE_NAME="$1"; }
safe_backup_target() { [[ "$1" == "$FIXTURE/"* ]]; }
backup_path() { safe_backup_target "$1" || die 'unsafe fixture path'; }
complete_backup() { :; }
'''

proxy_stub = r'''#!/usr/bin/env bash
set -Eeuo pipefail
printf 'proxy %s\n' "$*" >>"$FIXTURE/events"
if [[ -n "${TEST_CREATED_PHASE:-}" ]]; then
  active="$FIXTURE/backups/current-attempt"
  mkdir -p "$active"
  printf 'phase=%s\n' "$TEST_CREATED_PHASE" >"$active/MANIFEST.txt"
  : >"$active/paths.tsv"
  printf '%s\n' "$active" >"$FIXTURE/state/active-backup"
fi
exit "${TEST_PROXY_EXIT:-23}"
'''

rollback_stub = r'''#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rollback %s\n' "$*" >>"$FIXTURE/events"
'''

service_mock = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['FIXTURE'] + '/services.jsonl', 'a') as handle:
    handle.write(json.dumps([name, *sys.argv[1:]]) + '\n')
if name == 'systemctl' and sys.argv[1:] != ['daemon-reload']:
    raise SystemExit('unexpected service action')
if name == 'ufw' and sys.argv[1:] != ['reload']:
    raise SystemExit('unexpected firewall action')
if name not in {'systemctl', 'ufw'}:
    raise SystemExit('unexpected service command')
'''

with tempfile.TemporaryDirectory(prefix='vub-refresh-recovery-') as temporary:
    root = Path(temporary)

    def fixture(name):
        base = root / name
        for directory in ('scripts', 'bin', 'state', 'backups', 'etc'):
            (base / directory).mkdir(parents=True)
        (base / 'config.env').write_text('# isolated fixture\n')
        (base / 'scripts' / '00-lib.sh').write_text(library)
        shutil.copyfile(project / 'scripts' / 'desktop-proxy.sh', base / 'scripts' / 'desktop-proxy.sh')
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('VUB_', 'TEST_'))}
        environment.update(FIXTURE=str(base), PATH=f'{base / "bin"}:/usr/bin:/bin')
        return base, environment

    def run(command, base, environment, **overrides):
        return subprocess.run(command, cwd=base, env={**environment, **overrides},
                              text=True, capture_output=True, timeout=15)

    def events(base):
        path = base / 'events'
        return path.read_text().splitlines() if path.exists() else []

    def bootstrap_case(name, existing_phase='', created_phase='', code=23):
        base, environment = fixture(name)
        shutil.copyfile(project / 'bootstrap.sh', base / 'bootstrap.sh')
        (base / 'scripts' / '02-proxy.sh').write_text(proxy_stub)
        (base / 'scripts' / '10-rollback.sh').write_text(rollback_stub)
        # A regression that installs dependencies must be observable, never real.
        (base / 'scripts' / '00-dependencies.sh').write_text(
            '#!/bin/bash\nprintf "dependencies\\n" >>"$FIXTURE/events"\nexit 99\n')
        old_active = None
        if existing_phase:
            backup = base / 'backups' / 'previous-attempt'
            backup.mkdir()
            (backup / 'MANIFEST.txt').write_text(f'phase={existing_phase}\n')
            (backup / 'paths.tsv').write_text('')
            old_active = str(backup) + '\n'
            (base / 'state' / 'active-backup').write_text(old_active)
        result = run(['bash', str(base / 'bootstrap.sh'), '--phase', 'proxy-refresh'],
                     base, environment, TEST_CREATED_PHASE=created_phase, TEST_PROXY_EXIT=str(code))
        output = result.stdout + result.stderr
        assert result.returncode != 0 if existing_phase or code else result.returncode == 0, (name, output)
        actual = events(base)
        if existing_phase:
            assert actual == [], (name, actual, output)
            assert (base / 'state' / 'active-backup').read_text() == old_active
        elif created_phase == 'proxy' and code:
            assert actual == [
                'proxy refresh',
                f'rollback --backup {base / "backups" / "current-attempt"} --automatic',
            ], (name, actual, output)
        else:
            assert actual == ['proxy refresh'], (name, actual, output)
        return base

    bootstrap_case('prior-static', existing_phase='static-network')
    bootstrap_case('prior-proxy', existing_phase='proxy')
    bootstrap_case('new-proxy-failure', created_phase='proxy')
    base = bootstrap_case('foreign-backup-during-run', created_phase='network-refresh-ssh')
    assert (base / 'state' / 'active-backup').exists(), 'foreign backup pointer was removed'
    bootstrap_case('failure-before-backup')
    bootstrap_case('proxy-success', code=0)

    for dry_run in (False, True):
        base, environment = fixture('rollback-dry-run' if dry_run else 'rollback-live-fixture')
        shutil.copyfile(project / 'scripts' / '10-rollback.sh', base / 'scripts' / '10-rollback.sh')
        for name in ('systemctl', 'ufw', 'sshd', 'netplan'):
            path = base / 'bin' / name
            path.write_text(service_mock)
            path.chmod(0o755)
        environment['VUB_SSHD_BIN'] = str(base / 'bin' / 'sshd')
        backup = base / 'backups' / 'network-refresh-ssh'
        backup.mkdir()
        (backup / 'MANIFEST.txt').write_text('phase=network-refresh-ssh\n')
        target = base / 'etc' / 'fixture-ufw.rules'
        target.write_text('new firewall rules\n')
        saved = backup / 'rootfs' / str(target).lstrip('/')
        saved.parent.mkdir(parents=True)
        saved.write_text('old firewall rules\n')
        (backup / 'paths.tsv').write_text(f'present\t{target}\n')
        result = run(['bash', str(base / 'scripts' / '10-rollback.sh'),
                      '--backup', str(backup), '--automatic'], base, environment,
                     VUB_DRY_RUN='true' if dry_run else 'false')
        output = result.stdout + result.stderr
        assert result.returncode == 0, output
        log = base / 'services.jsonl'
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        if dry_run:
            assert not calls, calls
            assert target.read_text() == 'new firewall rules\n'
        else:
            assert target.read_text() == 'old firewall rules\n'
            assert calls.count(['ufw', 'reload']) == 1, (calls, output)
            assert all(call in (['systemctl', 'daemon-reload'], ['ufw', 'reload'])
                       for call in calls), calls

print('refresh recovery: PASS (8 isolated cases; no real network/service changes)')
PY
