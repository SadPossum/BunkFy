#!/usr/bin/env python3
"""Synthetic broker/cache/object canaries on the actual disposable Compose services."""

import argparse
import asyncio
import base64
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


async def exercise(config, state, mode, checks):
    import nats
    broker = config['nats']
    parsed = urllib.parse.urlsplit(broker['url'])
    require(parsed.scheme == 'nats' and ipaddress.ip_address(parsed.hostname).is_private,
            'Only an owned private broker endpoint is permitted.')
    connection = await nats.connect(broker['url'], user=broker['user'], password=broker['password'],
                                    connect_timeout=5, max_reconnect_attempts=0)
    async def api(path, value=None):
        response = await connection.request('$JS.API.' + path,
            b'' if value is None else json.dumps(value).encode(), timeout=8)
        result = json.loads(response.data)
        require('error' not in result, 'The real JetStream API refused a canary operation.')
        return result
    try:
        if mode == 'create':
            suffix = uuid.uuid4().hex[:20]
            state['stream'] = 'COD_CANARY_' + suffix
            state['subject'] = '_codex.canary.' + suffix
            state['consumer'] = 'RECOVERY'
            state['payloads'] = [base64.b64encode(os.urandom(64)).decode() for _ in range(2)]
            await api('STREAM.CREATE.' + state['stream'], {'name': state['stream'],
                'subjects': [state['subject']], 'storage': 'file'})
            for index, payload in enumerate(state['payloads'], 1):
                ack = json.loads((await connection.request(state['subject'], payload.encode(), timeout=8)).data)
                require(ack.get('seq') == index and 'error' not in ack, 'Broker did not persist the ordered canary messages.')
            await api('CONSUMER.DURABLE.CREATE.' + state['stream'] + '.' + state['consumer'],
                {'stream_name': state['stream'], 'config': {'durable_name': state['consumer'],
                 'ack_policy': 'explicit', 'deliver_policy': 'all', 'replay_policy': 'instant',
                 'filter_subject': state['subject']}})
        info = await api('STREAM.INFO.' + state['stream'])
        consumer = await api('CONSUMER.INFO.' + state['stream'] + '.' + state['consumer'])
        require(info['state']['last_seq'] == 2, 'Broker stream sequence was not preserved.')
        if mode == 'restore':
            require(consumer['ack_floor']['stream_seq'] == 1 and consumer['num_pending'] == 1
                    and consumer['num_ack_pending'] == 0, 'Restored durable acknowledgement state changed.')
        # Pull delivery preserves the original subject. The official client's
        # SID-based request mode avoids its inbox-token request multiplexer.
        message = await connection.request('$JS.API.CONSUMER.MSG.NEXT.' + state['stream'] + '.' + state['consumer'],
            json.dumps({'batch': 1, 'expires': 5_000_000_000}).encode(), timeout=8, old_style=True)
        index = 0 if mode == 'create' else 1
        require(message.subject == state['subject'] and message.data == state['payloads'][index].encode(),
                'Durable pull did not return the expected original-subject bytes.')
        await connection.publish(message.reply, b'+ACK')
        await connection.flush(timeout=5)
        expected = index + 1
        for _ in range(30):
            consumer = await api('CONSUMER.INFO.' + state['stream'] + '.' + state['consumer'])
            if consumer['ack_floor']['stream_seq'] == expected:
                break
            await asyncio.sleep(0.1)
        require(consumer['ack_floor']['stream_seq'] == expected and consumer['num_pending'] == 2 - expected,
                'The actual broker did not persist the expected consumer acknowledgement.')
        checks.append('actual-jetstream-file-state-and-durable-ack-' + mode)
    finally:
        await connection.close()

    identity = config['redisContainer']
    require(re.fullmatch(r'[a-f0-9]{64}', identity), 'Invalid owned cache container identity.')
    if mode == 'create':
        state['redisKey'] = 'codex:recovery:' + uuid.uuid4().hex
        state['redisValue'] = base64.b64encode(os.urandom(64)).decode()
    def redis(*args):
        result = subprocess.run(['docker', 'exec', identity, 'sh', '-eu', '-c',
            'REDISCLI_AUTH="$REDIS_PASSWORD"; export REDISCLI_AUTH; exec redis-cli --raw "$@"',
            '--', *args], capture_output=True, timeout=15)
        require(result.returncode == 0, 'The real private cache canary command failed.')
        return result.stdout.decode().rstrip('\r\n')
    if mode == 'create':
        require(redis('SET', state['redisKey'], state['redisValue']) == 'OK', 'Cache canary write failed.')
    require(redis('GET', state['redisKey']) == state['redisValue'], 'Cache AOF canary bytes did not survive.')
    checks.append('actual-redis-aof-canary-' + mode)

    root = Path(config['candidateRoot'])
    spec = importlib.util.spec_from_file_location('actual_s3', root / 'eng/operations/probe-preview-storage.py')
    storage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(storage)
    s3 = config['s3']
    endpoint = urllib.parse.urlsplit(s3['endpoint'])
    require(endpoint.scheme == 'http' and ipaddress.ip_address(endpoint.hostname).is_private,
            'Only the owned private S3 endpoint is permitted.')
    def request(method, path, **options):
        return storage.request(s3['endpoint'], s3['key'], s3['password'], method, path, **options)
    if mode == 'create':
        state['bucket'] = 'codex-recovery-' + uuid.uuid4().hex[:20]
        state['object'] = '/private-canary.bin'
        state['objectSha256'] = hashlib.sha256((payload := os.urandom(4096))).hexdigest()
        require(request('PUT', '/' + state['bucket'])[0] == 200, 'Private S3 bucket creation failed.')
        require(request('PUT', '/' + state['bucket'] + state['object'], body=payload,
                        headers={'x-amz-meta-file-name': 'backup-canary.bin',
                                 'x-amz-meta-kind': 'synthetic-recovery-canary'})[0] == 200,
                'Private S3 canary write failed.')
    path = '/' + state['bucket'] + state['object']
    status, data, _ = request('GET', path)
    require(status == 200 and hashlib.sha256(data).hexdigest() == state['objectSha256'],
            'Object canary bytes did not survive.')
    status, _, headers = request('HEAD', path)
    headers = {key.lower(): value for key, value in headers.items()}
    require(status == 200 and headers.get('x-amz-meta-file-name') == 'backup-canary.bin'
            and headers.get('x-amz-meta-kind') == 'synthetic-recovery-canary', 'Object metadata did not survive.')
    require(request('GET', path, signed=False)[0] == 403, 'Object canary became anonymously readable.')
    checks.append('actual-private-s3-bytes-metadata-and-denial-' + mode)


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('create', 'restore'))
    parser.add_argument('config', type=Path)
    parser.add_argument('state', type=Path)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    config = json.loads(args.config.read_text())
    state = {} if args.mode == 'create' else json.loads(args.state.read_text())
    report = {'schemaVersion': 1, 'mode': args.mode, 'result': 'failed', 'checks': [],
              'scope': 'Actual private services and synthetic persistence markers only; not production or cross-version migration acceptance.'}
    try:
        asyncio.run(exercise(config, state, args.mode, report['checks']))
        if args.mode == 'create':
            with args.state.open('x') as out:
                json.dump(state, out)
        report['result'] = 'passed'
    except Exception as error:
        report['failureType'] = type(error).__name__
    finally:
        with args.evidence.open('x') as out:
            json.dump(report, out, indent=2)
    if report['result'] != 'passed':
        raise SystemExit('Actual protocol canary failed; details remain private.')
