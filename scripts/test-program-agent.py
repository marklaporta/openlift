#!/usr/bin/env python3
"""Actual simulator private-file/URL/receipt gate. Only an explicitly named scratch simulator."""
import argparse
import atexit
import json
from pathlib import Path
import sqlite3
import plistlib
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def application_rows(store):
    connection = sqlite3.connect(f'file:{store}?mode=ro', uri=True)
    excluded = {'ACHANGE', 'ATRANSACTION', 'ATRANSACTIONSTRING', 'Z_PRIMARYKEY'}
    result = {}
    for (table,) in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall():
        if table in excluded:
            continue
        columns = [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")') if row[1] != 'Z_OPT']
        result[table] = sorted(connection.execute('SELECT ' + ','.join(f'"{c}"' for c in columns) + f' FROM "{table}"').fetchall(), key=repr)
    connection.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--state-dir', required=True, type=Path)
    args = parser.parse_args()
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', '--json'))['devices']
    device = next(d for entries in devices.values() for d in entries if d['udid'] == args.simulator)
    if not device['name'].startswith('OpenLift Bridge Verification '):
        parser.error('Refusing non-bridge-test simulator; create one named OpenLift Bridge Verification <unique ID>')
    args.state_dir.mkdir(parents=True, exist_ok=True)
    base = ['python3', str(ROOT / 'scripts/program-agent.py'), '--simulator', args.simulator, '--state-dir', str(args.state_dir)]
    def command(*suffix, expected=0):
        result = subprocess.run(base + list(suffix), capture_output=True, text=True)
        assert result.returncode == expected, result.stdout + result.stderr
        return json.loads(result.stdout)
    # simctl opens schemes through SpringBoard and presents an OS link dialog.
    # CoreDevice instead targets the bundle with --payload-url. The test runner
    # accepts simulator dialogs; program approval remains the explicit CLI call.
    products = ROOT / '.build/tests/DerivedData/Build/Products'
    descriptor = max(products.glob('OpenLift_*.xctestrun'), key=lambda p: p.stat().st_mtime)
    config = plistlib.loads(descriptor.read_bytes())
    for item in config['TestConfigurations']:
        item['TestTargets'] = [t for t in item['TestTargets'] if t['BlueprintName'] == 'OpenLiftUITests']
        for target in item['TestTargets']:
            target['EnvironmentVariables']['OPENLIFT_BRIDGE_TRANSPORT_UI'] = '1'
            target['EnvironmentVariables']['OPENLIFT_BRIDGE_RESULT_PATH'] = str(args.state_dir / 'test-result.json')
    # Preserve __TESTROOT__ resolution beside the original built descriptor.
    harness = products / 'OpenLiftBridgeTransport.xctestrun'
    harness.write_bytes(plistlib.dumps(config))
    log = (args.state_dir / 'system-link-harness.log').open('w')
    runner = subprocess.Popen(['xcodebuild', 'test-without-building', '-xctestrun', str(harness),
        '-destination', f'platform=iOS Simulator,id={args.simulator}', '-parallel-testing-enabled', 'NO',
        '-only-testing:OpenLiftUITests/ProgramBridgeTransportUITests/testAcceptSimulatorLinkDialogs',
        '-resultBundlePath', str(args.state_dir / 'system-link-harness.xcresult')], stdout=log, stderr=subprocess.STDOUT)
    def stop_harness():
        if runner.poll() is None:
            runner.terminate()
            try: runner.wait(timeout=10)
            except subprocess.TimeoutExpired: runner.kill()
    atexit.register(stop_harness)
    ready_deadline = time.monotonic() + 30
    while 'Test Case ' not in (args.state_dir / 'system-link-harness.log').read_text():
        assert runner.poll() is None and time.monotonic() < ready_deadline, 'System link harness did not start'
        time.sleep(0.2)
    container = Path(output('xcrun', 'simctl', 'get_app_container', args.simulator, 'com.mark.openlift', 'data'))
    store = container / 'Library/Application Support/default.store'
    # Normal launch must not scan even a staged command. First stabilize normal
    # bootstrap, then compare application fields across read-only bridge calls.
    warm_pid = output('xcrun', 'simctl', 'launch', args.simulator, 'com.mark.openlift')
    time.sleep(2)
    before = application_rows(store)
    starter_path = args.state_dir / 'revision.json'
    starter = command('starter', '--output', str(starter_path))
    assert starter['blockedByDraft'] is False
    assert application_rows(store) == before, 'Starter changed application fields'
    preview = command('preview', str(starter_path))
    assert preview['status'] == 'previewed' and len(preview['upcoming']) == 3
    assert application_rows(store) == before, 'Preview changed application fields'
    # A valid approved but unsignaled inbox command is inert on normal startup.
    inert_id = str(uuid.uuid4())
    inert = {'protocolVersion': 1, 'id': inert_id, 'action': 'apply', 'expiresAt': time.time() + 600,
             **{k: preview[k] for k in ['previewID', 'approvalToken', 'revisionSHA256']}}
    inert_path = container / 'Library/Application Support/OpenLiftAgentBridge/inbox' / (inert_id + '.json')
    inert_path.write_text(json.dumps(inert))
    output('xcrun', 'simctl', 'terminate', args.simulator, 'com.mark.openlift')
    warm_pid = output('xcrun', 'simctl', 'launch', args.simulator, 'com.mark.openlift')
    time.sleep(2)
    assert application_rows(store) == before, 'Normal startup consumed an unsignaled apply'
    # Same process remains alive during foreground URL delivery (no terminate).
    applied = command('apply', '--approved-preview', preview['receiptPath'])
    assert output('xcrun', 'simctl', 'launch', args.simulator, 'com.mark.openlift') == warm_pid, 'Warm handoff restarted the process'
    assert applied['status'] == 'applied' and applied['appliedVersion'].endswith('.v9')
    after = application_rows(store)
    allowed = {'ZCYCLETEMPLATE', 'ZCYCLEDAY', 'ZCYCLESLOT', 'ZROTATIONPOOL', 'ZCLUSTERROTATIONSTATE', 'ZACTIVECYCLEINSTANCE', 'ZTRAININGPREFERENCE'}
    for table, rows in before.items():
        if table not in allowed:
            assert after.get(table) == rows, table
    repeated = command('retry', applied['requestID'].lower())
    assert repeated['backupPath'] == applied['backupPath']
    assert application_rows(store) == after, 'Replay changed application fields'
    # Cold URL dispatch is distinct from warm dispatch.
    output('xcrun', 'simctl', 'terminate', args.simulator, 'com.mark.openlift')
    status = command('status')
    assert status['starter']['sourceProgramVersionID'].endswith('.v9')
    time.sleep(1)
    assert application_rows(store) == after, 'Cold reopen changed application fields'
    # URL without a privately staged request is powerless.
    output('xcrun', 'simctl', 'openurl', args.simulator, 'openlift-agent://request/00000000-0000-0000-0000-000000000000')
    time.sleep(1)
    assert application_rows(store) == after
    result = {'result': 'passed', 'warmApply': applied['requestID'], 'coldStatus': status['requestID'], 'stateDirectory': str(args.state_dir)}
    (args.state_dir / 'test-result.json').write_text(json.dumps(result, indent=2) + '\n')
    assert runner.wait(timeout=90) == 0, 'System link harness failed; inspect its log'
    log.close()
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
