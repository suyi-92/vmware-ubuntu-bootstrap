#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Execute the real refresh action and network inspection against temporary
# fixtures. Every external network/system operation is replaced before launch.
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])

library = r'''#!/usr/bin/env bash
VUB_ETC_DIR=/test-vub/etc
VUB_STATE_DIR=/test-vub/state
VUB_SCRIPT_DIR="$VUB_PROJECT_DIR/scripts"
source "$VUB_SCRIPT_DIR/network-lib.sh"
require_root() { :; }
load_config() { source "$VUB_CONFIG_FILE"; }
resolve_real_user() {
  REAL_USER=fixture; REAL_HOME="$TEST_CAPTURE_DIR/home"; REAL_GROUP=fixture
}
info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
is_true() { [[ "$1" == true ]]; }
is_dry_run() { return 0; }
start_phase() { printf 'phase %s\n' "$*" >>"$TEST_CAPTURE_DIR/phases"; }
validate_port() {
  local value="${!1}"
  [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 65535)) || die 'invalid port'
}
require_command() { command -v "$1" >/dev/null || die "missing $1"; }
shell_quote() { printf '%q' "$1"; }
write_managed_file() {
  local name="${1#/}"
  name="${name//\//__}"
  cat >"$TEST_CAPTURE_DIR/$name"
}
replace_marked_block() { write_managed_file "$1"; }
render_template() { printf 'fixture template %s\n' "$*"; }
visudo() { printf 'visudo %s\n' "$*" >>"$TEST_CAPTURE_DIR/phases"; }
complete_backup() { printf 'backup complete\n' >>"$TEST_CAPTURE_DIR/phases"; }
mark_phase() { printf 'mark %s\n' "$*" >>"$TEST_CAPTURE_DIR/phases"; }
systemctl() {
  [[ "$*" == 'list-unit-files --type=service' ]] || die 'unexpected systemctl mutation'
  return 1
}
command() {
  if [[ "$1" == -v && ( "$2" == docker || "$2" == snap ) ]]; then return 1; fi
  builtin command "$@"
}
backup_path() { die 'unexpected backup in dry-run'; }
run() { die 'unexpected external mutation'; }
init_input_tty() { die 'unexpected interactive selection'; }
'''

ip_mock = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
interface = os.environ.get('TEST_LIVE_INTERFACE', 'ens160')
if args == ['-j', 'link', 'show']:
    data = [{'ifname': interface, 'link_type': 'ether', 'address': '02:00:00:00:00:01'}]
elif args == ['-j', '-4', 'addr', 'show']:
    data = [{'ifname': interface, 'addr_info': [
        {'family': 'inet', 'local': '10.20.30.40', 'prefixlen': 23, 'scope': 'global'}]}]
elif args == ['-j', '-4', 'route', 'show', 'default']:
    data = [{'dev': interface, 'gateway': '10.20.30.1'}]
else:
    raise SystemExit('unexpected ip call: ' + repr(args))
print(json.dumps(data))
'''

curl_mock = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['TEST_CAPTURE_DIR'] + '/curl.jsonl', 'a') as handle:
    handle.write(json.dumps(args) + '\n')
try:
    assert args[args.index('--noproxy') + 1] == ''
    proxy = args[args.index('--proxy') + 1]
    host = proxy.removeprefix('http://').split(':')[0]
    assert host in os.environ['TEST_VALID_HOSTS'].split(',')
except (ValueError, IndexError, AssertionError):
    print('000 200', end='')
    raise SystemExit(97)
target = 'registry' if 'registry-1.docker.io' in args[-1] else 'github'
plan = json.loads(os.environ.get('TEST_CURL_PLAN', '{}')).get(target, [])
counter = os.environ['TEST_CAPTURE_DIR'] + '/count-' + target
try:
    with open(counter) as handle:
        count = int(handle.read())
except FileNotFoundError:
    count = 0
with open(counter, 'w') as handle:
    handle.write(str(count + 1))
if plan:
    status, code, message = plan[min(count, len(plan) - 1)]
    print(str(status) + ' 200', end='')
    print(message, file=sys.stderr)
    raise SystemExit(code)
if args[-1] == 'https://registry-1.docker.io/v2/':
    print('401 200', end='')
elif args[-1] == 'https://github.com/':
    print('200 200', end='')
else:
    raise SystemExit('unexpected URL')
'''

scanner_mock = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_CAPTURE_DIR'] + '/scan.json', 'w') as handle:
    json.dump(sys.argv[1:], handle)
print(os.environ.get('TEST_CANDIDATES', '10.20.30.7'))
raise SystemExit(int(os.environ.get('TEST_SCAN_EXIT', '0')))
'''

with tempfile.TemporaryDirectory(prefix='vub-proxy-refresh-') as temporary:
    root = Path(temporary)
    scripts = root / 'scripts'
    commands = root / 'bin'
    scripts.mkdir()
    commands.mkdir()
    for filename in ('02-proxy.sh', 'network-lib.sh', 'network_config.py', 'desktop-proxy.sh'):
        shutil.copyfile(project / 'scripts' / filename, scripts / filename)
    (scripts / '00-lib.sh').write_text(library)
    (scripts / 'proxy_scan.py').write_text(scanner_mock)
    for name, content in (('ip', ip_mock), ('curl', curl_mock)):
        path = commands / name
        path.write_text(content)
        path.chmod(0o755)
    config = root / 'config.env'
    config.write_text('''NETWORK_INTERFACE=ens160
PROXY_HOST=192.168.99.7
PROXY_PORT=7890
PROXY_SCAN_CIDR=192.168.99.0/24
CONFIGURE_STATIC_NETWORK=true
STATIC_IPV4_CIDR=192.168.99.40/24
GATEWAY_IPV4=192.168.99.1
CPA_BASE_URL=
''')
    original_config = config.read_bytes()

    def run_case(name, *, success=True, message='', **overrides):
        capture = root / name
        capture.mkdir()
        environment = os.environ.copy()
        # Ignore settings from the developer's own shell; mock HTTP calls only.
        for key in ('VUB_FORCE_PROXY_HOST', 'VUB_REFRESH_PROXY_PORT', 'VUB_REFRESH_INTERFACE'):
            environment.pop(key, None)
        environment.update(
            PATH=str(commands) + os.pathsep + os.environ['PATH'],
            VUB_PROJECT_DIR=str(root), VUB_CONFIG_FILE=str(config),
            VUB_YES='true', VUB_DRY_RUN='true',
            TEST_CAPTURE_DIR=str(capture), TEST_VALID_HOSTS='10.20.30.7',
            no_proxy='*', NO_PROXY='*',
        )
        environment.update(overrides)
        result = subprocess.run(
            ['bash', str(scripts / '02-proxy.sh'), 'refresh'],
            env=environment, text=True, capture_output=True, timeout=20,
        )
        output = result.stdout + result.stderr
        assert (result.returncode == 0) == success, (name, result.returncode, output)
        assert message in output, (name, output)
        state = capture / 'test-vub__etc__proxy.env'
        assert state.exists() == success, (name, 'unexpected proxy persistence', output)
        assert config.read_bytes() == original_config, 'source config changed'
        curls = capture / 'curl.jsonl'
        calls = [json.loads(line) for line in curls.read_text().splitlines()] if curls.exists() else []
        for arguments in calls:
            assert arguments[arguments.index('--noproxy') + 1] == '', arguments
            assert arguments[arguments.index('--connect-timeout') + 1] == '8', arguments
            assert arguments[arguments.index('--max-time') + 1] == '20', arguments
        if success:
            state_text = state.read_text()
            assert 'no_proxy=' in state_text
            assert '10.20.30.0/23' in state_text, state_text
            assert '10.20.30.1' in state_text, state_text
            assert '192.168.99.' not in state_text, state_text
        return capture, calls

    capture, calls = run_case('new-lan')
    assert json.loads((capture / 'scan.json').read_text()) == [
        '--cidr', '10.20.30.0/24', '--self-ip', '10.20.30.40', '--port', '7890']
    assert len(calls) == 2, calls
    assert all(arguments[arguments.index('--proxy') + 1] == 'http://10.20.30.7:7890'
               for arguments in calls)
    assert 'http_proxy=http://10.20.30.7:7890' in (capture / 'test-vub__etc__proxy.env').read_text()

    capture, calls = run_case(
        'explicit-proxy', VUB_FORCE_PROXY_HOST='10.20.30.8', VUB_REFRESH_PROXY_PORT='8899',
        TEST_VALID_HOSTS='10.20.30.8')
    assert not (capture / 'scan.json').exists(), 'explicit host unexpectedly scanned'
    assert len(calls) == 2, calls
    assert all(arguments[arguments.index('--proxy') + 1] == 'http://10.20.30.8:8899'
               for arguments in calls)
    assert 'VUB_PROXY_PORT=8899' in (capture / 'test-vub__etc__proxy.env').read_text()

    capture, calls = run_case(
        'explicit-interface', VUB_REFRESH_INTERFACE='ens192', TEST_LIVE_INTERFACE='ens192')
    assert (capture / 'scan.json').exists() and len(calls) == 2

    capture, calls = run_case(
        'failed-scan', success=False, message='代理扫描失败', TEST_SCAN_EXIT='23')
    assert not calls, 'partial output from a failed scan was verified or applied'

    capture, calls = run_case(
        'multiple-proxies', success=False, message='非交互模式不会替你选择多个代理',
        TEST_CANDIDATES='10.20.30.7\n10.20.30.8', TEST_VALID_HOSTS='10.20.30.7,10.20.30.8')
    assert len(calls) == 4, calls

    capture, calls = run_case(
        'unusable-proxy', success=False, message='没有找到可用代理', TEST_VALID_HOSTS='')
    assert len(calls) == 1, calls

    capture, calls = run_case(
        'invalid-port', success=False, message='invalid port', VUB_REFRESH_PROXY_PORT='70000')
    assert not calls and not (capture / 'scan.json').exists()

    capture, calls = run_case(
        'transient-timeout', message='1 秒后重试一次',
        TEST_CURL_PLAN=json.dumps({'registry': [['000', 28, 'TLS connection timeout'], ['401', 0, '']]}))
    assert len(calls) == 3, calls

    capture, calls = run_case(
        'persistent-timeout', success=False, message='Docker Registry 验证失败',
        TEST_CURL_PLAN=json.dumps({'registry': [['000', 28, 'TLS connection timeout']]}))
    assert len(calls) == 2, calls

    capture, calls = run_case(
        'certificate-error', success=False, message='curl=60',
        TEST_CURL_PLAN=json.dumps({'registry': [['000', 60, 'certificate verify failed']]}))
    assert len(calls) == 1, calls

    capture, calls = run_case(
        'proxy-auth', success=False, message='HTTP=407',
        TEST_CURL_PLAN=json.dumps({'registry': [['407', 0, '']]}))
    assert len(calls) == 1, calls

    capture, calls = run_case(
        'github-forbidden', success=False, message='GitHub 验证失败',
        TEST_CURL_PLAN=json.dumps({'github': [['403', 0, '']]}))
    assert len(calls) == 2, calls

    capture, calls = run_case(
        'incomplete-success-code', success=False, message='curl=18',
        TEST_CURL_PLAN=json.dumps({'registry': [['401', 18, 'partial transfer']]}))
    assert len(calls) == 2, calls

print('proxy refresh: PASS (13 isolated cases; no real network/system changes)')
PY
