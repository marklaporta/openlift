#!/usr/bin/env python3
"""Paired-host OpenLift program bridge; never terminates the app or edits its store."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

BRIDGE = Path('Library/Application Support/OpenLiftAgentBridge')


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


class Transport:
    def __init__(self, args):
        self.args = args
        self.container = None
        if args.simulator:
            result = run(['xcrun', 'simctl', 'get_app_container', args.simulator, args.bundle_id, 'data'])
            if result.returncode:
                raise RuntimeError(result.stderr.strip())
            self.container = Path(result.stdout.strip())

    def copy(self, direction, source, destination):
        if self.container:
            src = Path(source) if direction == 'to' else self.container / source
            dest = self.container / destination if direction == 'to' else Path(destination)
            if not src.exists():
                return False
            dest.parent.mkdir(parents=True, exist_ok=True)
            if direction == 'to':
                temporary = dest.with_suffix('.partial')
                shutil.copyfile(src, temporary)
                os.replace(temporary, dest)
            else:
                shutil.copyfile(src, dest)
            return True
        result = run(['xcrun', 'devicectl', 'device', 'copy', direction, '--device', self.args.device,
                      '--domain-type', 'appDataContainer', '--domain-identifier', self.args.bundle_id,
                      '--source', str(source), '--destination', str(destination), '--timeout', '15', '--quiet'])
        return result.returncode == 0

    def signal(self, request_id):
        url = f'openlift-agent://request/{request_id}'
        if self.container:
            result = run(['xcrun', 'simctl', 'openurl', self.args.simulator, url])
        else:
            result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', self.args.device,
                          '--payload-url', url, '--timeout', '20', '--quiet', self.args.bundle_id])
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    host = parser.add_mutually_exclusive_group(required=True)
    host.add_argument('--device', help='paired CoreDevice identifier (development installation required)')
    host.add_argument('--simulator', help='simulator UDID (scratch testing only)')
    parser.add_argument('--bundle-id', default='com.mark.openlift')
    parser.add_argument('--state-dir', required=True, type=Path, help='private local request/receipt archive, outside source control')
    parser.add_argument('--wait', type=int, default=30)
    subs = parser.add_subparsers(dest='action', required=True)
    for action in ['status', 'starter']:
        sub = subs.add_parser(action)
        sub.add_argument('--output', type=Path, help='write revision starter here after a successful response')
    preview = subs.add_parser('preview')
    preview.add_argument('revision', type=Path)
    apply = subs.add_parser('apply')
    apply.add_argument('--approved-preview', required=True, type=Path, help='exact reviewed preview receipt; constitutes explicit apply instruction')
    retry = subs.add_parser('retry')
    retry.add_argument('request_id', type=lambda value: str(uuid.UUID(value)))
    args = parser.parse_args()
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(args.state_dir, 0o700)
    if args.action == 'retry':
        request_id = args.request_id
        request_path = args.state_dir / f'{request_id}.request.json'
        data = request_path.read_bytes()
        request = json.loads(data)
        if request['id'] != request_id:
            parser.error('Archived request ID mismatch')
    else:
        request_id = str(uuid.uuid4())
        request = {'protocolVersion': 1, 'id': request_id, 'action': args.action, 'expiresAt': time.time() + 900}
        if args.action == 'preview':
            revision = args.revision.read_bytes()
            if len(revision) > 262144:
                parser.error('Revision exceeds 256 KB')
            json.loads(revision)
            request['revision'] = base64.b64encode(revision).decode()
        elif args.action == 'apply':
            receipt = json.loads(args.approved_preview.read_bytes())
            if receipt.get('status') != 'previewed' or receipt.get('blockedByDraft') or receipt.get('expiresAt', 0) <= time.time():
                parser.error('A current, unblocked reviewed preview receipt is required; preview again')
            request.update({key: receipt[key] for key in ['previewID', 'approvalToken', 'revisionSHA256']})
            request['expiresAt'] = min(request['expiresAt'], receipt['expiresAt'])
        data = encoded(request)
        request_path = args.state_dir / f'{request_id}.request.json'
        with request_path.open('xb') as stream:
            stream.write(data)
        os.chmod(request_path, 0o600)
    digest = hashlib.sha256(data).hexdigest()
    transport = Transport(args)
    remote_request = BRIDGE / 'inbox' / f'{request_id}.json'
    remote_receipt = BRIDGE / 'receipts' / f'{request_id}.json'
    receipt_path = args.state_dir / f'{request_id}.receipt.json'
    # CoreDevice copy completes before the wake signal; no directory scan can
    # observe a partial transfer. Retries resend exactly the retained bytes.
    if not transport.copy('to', request_path, remote_request):
        print(json.dumps({'status': 'transport_error', 'requestID': request_id, 'message': 'Staging failed; no wake sent. Retry the same request ID.'}))
        return 3
    signal = transport.signal(request_id)
    deadline = time.monotonic() + max(1, min(args.wait, 120))
    with tempfile.TemporaryDirectory(prefix='openlift-receipt-') as directory:
        temporary = Path(directory) / 'receipt.json'
        while time.monotonic() < deadline:
            if transport.copy('from', remote_receipt, temporary):
                try:
                    receipt = json.loads(temporary.read_bytes())
                    if receipt['requestID'].lower() != request_id or receipt['requestSHA256'] != digest:
                        raise RuntimeError('Receipt identity mismatch; original device receipt retained')
                    # In-flight intent can be visible before apply completes.
                    if receipt['status'] != 'interrupted':
                        shutil.copyfile(temporary, receipt_path)
                        os.chmod(receipt_path, 0o600)
                        if getattr(args, 'output', None) and receipt.get('starter'):
                            args.output.write_bytes(json.dumps(receipt['starter'], indent=2).encode() + b'\n')
                            os.chmod(args.output, 0o600)
                        print(json.dumps({'receiptPath': str(receipt_path), **receipt}, indent=2))
                        return 0 if receipt['status'] in ['ok', 'previewed', 'applied'] else 2
                except json.JSONDecodeError:
                    pass
            time.sleep(0.5)
    print(json.dumps({'status': 'unknown', 'requestID': request_id,
                      'message': 'No terminal receipt obtained. Do not infer failure or submit another apply. Retry this exact request ID to reconcile.',
                      'wakeAccepted': signal.returncode == 0}))
    return 3


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(json.dumps({'status': 'client_error', 'message': str(error)}))
        sys.exit(3)
