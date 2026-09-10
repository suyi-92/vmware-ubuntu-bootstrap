#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
initial = {
    'org.gnome.system.proxy.http host': "''",
    'org.gnome.system.proxy.http port': '8080',
    'org.gnome.system.proxy.http enabled': 'false',
    'org.gnome.system.proxy.http use-authentication': 'false',
    'org.gnome.system.proxy.https host': "''",
    'org.gnome.system.proxy.https port': '0',
    'org.gnome.system.proxy ignore-hosts': "['localhost', '127.0.0.0/8', '::1']",
    'org.gnome.system.proxy mode': "'none'",
}
driver = r'''#!/bin/bash
set -Eeuo pipefail
source "$PROJECT/scripts/desktop-proxy.sh"
REAL_UID=1000; REAL_USER=fixture; REAL_HOME="$FIXTURE/home"
VUB_STATE_DIR="$FIXTURE/state"
VUB_BACKUP_DIR="$FIXTURE/backup-$BACKUP_NAME"
info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
is_dry_run() { [[ "${DRY_RUN:-false}" == true ]]; }
desktop_proxy_available() { [[ "${AVAILABLE:-true}" == true ]]; }
desktop_proxy_settings() { python3 "$FIXTURE/settings.py" "$@"; }
desktop_proxy_session() { python3 "$FIXTURE/session.py" "$@"; }
init_backup_dir() { mkdir -p "$VUB_BACKUP_DIR"; }
write_managed_file() { mkdir -p "$(dirname "$1")"; cat >"$1"; }
remove_managed_path() { rm -f -- "$1"; }
case "$ACTION" in
  apply) desktop_proxy_apply "$HOST" 7890 'localhost,127.0.0.1,::1,.local,192.168.2.0/24' ;;
  disable) desktop_proxy_disable ;;
  rollback) desktop_proxy_rollback "$FIXTURE/backup-$SOURCE_NAME" ;;
esac
'''
settings = r'''import json, os, pathlib, sys
path = pathlib.Path(os.environ['FIXTURE']) / 'settings.json'
data = json.loads(path.read_text())
action, schema, key, *values = sys.argv[1:]
name = schema + ' ' + key
assert name in data, name
if action == 'get':
    print(data[name])
elif action == 'writable':
    print('false' if os.getenv('LOCKED_KEY') == key else 'true')
elif action == 'set':
    if os.getenv('FAIL_KEY') == name:
        raise SystemExit(1)
    data[name] = values[0]
    path.write_text(json.dumps(data))
else:
    raise SystemExit('unexpected gsettings operation')
'''
with tempfile.TemporaryDirectory(prefix='vub-desktop-proxy-') as temporary:
    base = Path(temporary)
    (base / 'session.py').write_text('''import json, os, pathlib, sys
p = pathlib.Path(os.environ['FIXTURE']) / 'session.json'
if sys.argv[1] == 'snapshot':
    print(json.dumps(json.loads(p.read_text()) if p.exists() else {}, sort_keys=True))
else:
    if os.getenv('FAIL_SESSION'):
        raise SystemExit(1)
    p.write_text(json.dumps(json.load(sys.stdin), sort_keys=True))
''')
    (base / 'settings.py').write_text(settings)
    (base / 'driver.sh').write_text(driver)
    target = base / 'settings.json'
    target.write_text(json.dumps(initial))
    env = {**os.environ, 'FIXTURE': str(base), 'PROJECT': str(project)}
    def run(action='apply', name='a', success=True, **extra):
        result = subprocess.run(['bash', str(base / 'driver.sh')],
            env={**env, 'ACTION': action, 'BACKUP_NAME': name, 'HOST': '192.168.2.119', **extra},
            capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result.stdout + result.stderr

    run(DRY_RUN='true')
    assert json.loads(target.read_text()) == initial and not (base / 'backup-a').exists()
    run(AVAILABLE='false')
    assert json.loads(target.read_text()) == initial and not (base / 'state').exists()
    run(success=False, LOCKED_KEY='mode')
    assert json.loads(target.read_text()) == initial and not (base / 'state').exists()

    run()
    applied = json.loads(target.read_text())
    session_applied = json.loads((base / 'session.json').read_text())
    assert session_applied['HTTPS_PROXY'] == 'http://192.168.2.119:7890'
    assert session_applied['no_proxy'] == 'localhost,127.0.0.1,::1,.local,192.168.2.0/24'
    assert applied['org.gnome.system.proxy mode'] == "'manual'"
    assert applied['org.gnome.system.proxy.https host'] == "'192.168.2.119'"
    assert '*.local' in applied['org.gnome.system.proxy ignore-hosts']
    assert '192.168.2.0/24' in applied['org.gnome.system.proxy ignore-hosts']
    previous = base / 'state/desktop-proxy-1000.previous.tsv'
    original_saved = previous.read_bytes()

    run(name='b', HOST='192.168.2.120')
    assert previous.read_bytes() == original_saved
    run(action='rollback', name='rollback-b', SOURCE_NAME='b')
    assert json.loads(target.read_text()) == applied
    assert json.loads((base / 'session.json').read_text()) == session_applied
    run(action='disable', name='off', success=True)
    # The file transaction is outside this helper: after manual helper rollback,
    # managed.tsv still describes .120, so do not overwrite the user's .119 state.
    assert json.loads(target.read_text()) == applied and previous.exists()

    run(name='c')
    run(action='disable', name='off-c')
    assert json.loads(target.read_text()) == initial
    assert json.loads((base / 'session.json').read_text()) == {}
    assert not previous.exists()

    run(name='session-failed', success=False, FAIL_SESSION='1')
    run(action='rollback', name='rollback-session-failed', SOURCE_NAME='session-failed')
    assert json.loads(target.read_text()) == initial
    assert json.loads((base / 'session.json').read_text()) == {}

    run(name='failed', success=False, FAIL_KEY='org.gnome.system.proxy.https host')
    run(action='rollback', name='rollback-failed', SOURCE_NAME='failed')
    assert json.loads(target.read_text()) == initial
    (base / 'backup-failed/desktop-proxy.uid').write_text('2000\n')
    run(action='rollback', name='wrong-user', SOURCE_NAME='failed', success=False)
    assert json.loads(target.read_text()) == initial

    run(name='foreign-session')
    external_session = {'HTTPS_PROXY': 'http://operator.example:8080'}
    (base / 'session.json').write_text(json.dumps(external_session))
    run(action='disable', name='off-foreign-session')
    assert json.loads(target.read_text()) == initial
    assert json.loads((base / 'session.json').read_text()) == external_session
    assert (base / 'state/session-proxy-1000.previous.json').exists()

print('desktop proxy: PASS (GNOME and session refresh, dry-run, backup, disable, rollback, failures, foreign edits and UID)')
PY
