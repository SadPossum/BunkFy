#!/usr/bin/env python3
"""Bounded real Redis/NATS/Mailpit/archive compatibility; no application builds."""

import asyncio
import argparse
import base64
import datetime
from email.message import EmailMessage
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import secrets
import smtplib
import subprocess
import time
import traceback
import urllib.request
import uuid


LABEL = 'com.bunkfy.review.owner'


class Probe:
    def __init__(self, policy):
        self.policy = policy
        self.owner = 'bunkfy-state-review-' + uuid.uuid4().hex
        self.password = secrets.token_hex(32)
        self.network = self.owner + '-network'
        self.network_created = False
        self.containers = []
        self.volumes = []
        self.observations = []
        self.destination = Path('artifacts/state-compatibility')
        self.destination.mkdir(parents=True, exist_ok=True)

    def run(self, arguments, *, check=True, binary=False, input_data=None, timeout=90):
        result = subprocess.run(arguments, capture_output=True, text=not binary,
                                input=input_data, timeout=timeout)
        if check and result.returncode:
            error = result.stderr.decode(errors='replace') if binary else result.stderr
            raise RuntimeError('Owned probe command failed: ' + arguments[0] + ' ' + arguments[1] +
                               ': ' + error.replace(self.password, '[REDACTED]')[-1600:])
        return result

    def inspect(self, kind, identity):
        values = json.loads(self.run(['docker', kind, 'inspect', identity]).stdout)
        if len(values) != 1:
            raise RuntimeError('Unexpected resource identity.')
        return values[0]

    def owned(self, kind, identity):
        value = self.inspect(kind, identity)
        labels = value.get('Labels') if kind in ('network', 'volume') else value['Config'].get('Labels')
        if not labels or labels.get(LABEL) != self.owner:
            raise RuntimeError('Refusing an operation on an unowned Docker resource.')
        return value

    def check(self, condition, case, **details):
        if not condition:
            raise RuntimeError('Compatibility observation failed: ' + case)
        self.observations.append({'case': case, 'passed': True, **details})

    def volume(self, suffix):
        name = self.owner + '-' + suffix
        self.run(['docker', 'volume', 'create', '--label', LABEL + '=' + self.owner, name])
        self.volumes.append(name)
        self.owned('volume', name)
        return name

    def create(self, suffix, image, *, data=None, environment=None, command=None, ports=(),
               tmpfs=(), entrypoint=None, offline=False, read_only=False, interactive=False):
        args = ['docker', 'create', '--name', self.owner + '-' + suffix,
                '--label', LABEL + '=' + self.owner, '--network', 'none' if offline else self.network,
                '--memory', '512m', '--memory-swap', '512m', '--cpus', '1', '--pids-limit', '128',
                '--security-opt', 'no-new-privileges:true']
        if read_only:
            args.append('--read-only')
        if interactive:
            args.append('--interactive')
        for mount in data or []:
            self.owned('volume', mount[0])
            args += ['--mount', 'type=volume,src=' + mount[0] + ',dst=' + mount[1] +
                     (',readonly' if len(mount) > 2 and mount[2] else '')]
        for key, value in (environment or {}).items():
            args += ['--env', key + '=' + value]
        for port in ports:
            args += ['--publish', '127.0.0.1::' + str(port)]
        for mount in tmpfs:
            args += ['--tmpfs', mount]
        if entrypoint:
            args += ['--entrypoint', entrypoint]
        args += [self.policy['images'][image]['image'], *(command or [])]
        identity = self.run(args).stdout.strip()
        if re.fullmatch(r'[a-f0-9]{64}', identity) is None:
            raise RuntimeError('Unexpected container identity.')
        self.containers.append(identity)
        self.owned('container', identity)
        return identity

    def start(self, identity):
        self.owned('container', identity)
        self.run(['docker', 'start', identity])

    def stop(self, identity):
        if self.owned('container', identity)['State']['Running']:
            self.run(['docker', 'stop', '--time', '15', identity])

    def port(self, identity, number):
        mappings = self.owned('container', identity)['NetworkSettings']['Ports'][str(number) + '/tcp']
        if len(mappings) != 1 or mappings[0]['HostIp'] != '127.0.0.1':
            raise RuntimeError('Fixture ports must bind loopback only.')
        return int(mappings[0]['HostPort'])

    def wait(self, operation, description, timeout=30):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                return operation()
            except Exception as error:
                last = error
                time.sleep(0.2)
        raise RuntimeError(description + ' readiness failed: ' + str(last).replace(self.password, '[REDACTED]'))

    def archive(self, volume, utility='archive'):
        identity = self.create('archive-' + uuid.uuid4().hex[:8], utility,
                               data=[(volume, '/state', True)], offline=True,
                               entrypoint='tar', command=['-czf', '-', '-C', '/state', '.'])
        data = self.run(['docker', 'start', '--attach', identity], binary=True).stdout
        if not data.startswith(b'\x1f\x8b') or len(data) > 16_000_000:
            raise RuntimeError('Unexpected disposable state archive.')
        return data

    def restore(self, volume, data, utility='archive'):
        identity = self.create('restore-' + uuid.uuid4().hex[:8], utility,
                               data=[(volume, '/state')], offline=True,
                               entrypoint='tar', command=['-xzf', '-', '-C', '/state'], interactive=True)
        # docker start --interactive forwards the trusted fixture archive to tar.
        self.run(['docker', 'start', '--attach', '--interactive', identity],
                 binary=True, input_data=data)

    def utility(self, volume, script, utility='archive'):
        identity = self.create('utility-' + uuid.uuid4().hex[:8], utility,
                               data=[(volume, '/state')], offline=True, entrypoint='sh',
                               command=['-ec', script])
        return self.run(['docker', 'start', '--attach', identity]).stdout.strip()

    def redis(self):
        data = self.volume('redis-data')
        def server(suffix, image, volume):
            identity = self.create(suffix, image, data=[(volume, '/data')],
                                   command=['redis-server', '--appendonly', 'yes', '--requirepass', self.password])
            self.start(identity)
            self.wait(lambda: command(identity, 'PING'), suffix)
            return identity
        def command(identity, *arguments, password=None, check=True):
            self.owned('container', identity)
            result = self.run(['docker', 'exec', '--env', 'REDISCLI_AUTH=' + (password or self.password),
                               identity, 'redis-cli', '--no-auth-warning', '-e', '--raw', *arguments], check=check)
            return result.stdout.strip() if check else result
        def snapshot(identity):
            fields = command(identity, 'HGETALL', 'compat:hash').splitlines()
            return {'session': command(identity, 'GET', 'compat:session'),
                    'hash': dict(zip(fields[::2], fields[1::2])),
                    'set': sorted(command(identity, 'SMEMBERS', 'compat:set').splitlines()),
                    'sortedSet': command(identity, 'ZRANGE', 'compat:rank', '0', '-1', 'WITHSCORES').splitlines(),
                    'stream': command(identity, 'XRANGE', 'compat:stream', '-', '+').splitlines(),
                    'counter': command(identity, 'GET', 'compat:counter')}
        old = server('redis-old', 'redisOld', data)
        command(old, 'SET', 'compat:session', 'fixture-session', 'EX', '1800')
        command(old, 'HSET', 'compat:hash', 'north', '1', 'south', '2')
        command(old, 'SADD', 'compat:set', 'north', 'south')
        command(old, 'ZADD', 'compat:rank', '2', 'south', '1', 'north')
        command(old, 'XADD', 'compat:stream', '*', 'event', 'fixture-only')
        self.check(command(old, 'EVAL', "return redis.call('INCR',KEYS[1])", '1', 'compat:counter') == '1',
                   'redis-old-authenticated-lua-counter')
        baseline = snapshot(old)
        self.stop(old)
        old_archive = self.archive(data)
        new = server('redis-new', 'redis', data)
        self.check(snapshot(new) == baseline, 'redis-old-aof-state-opens-on-new-server')
        self.check(0 < int(command(new, 'TTL', 'compat:session')) <= 1800, 'redis-expiry-preserved')
        bad = command(new, 'PING', password='wrong-fixture-password', check=False)
        self.check(bad.returncode != 0 and ('WRONGPASS' in bad.stderr + bad.stdout or 'NOAUTH' in bad.stderr + bad.stdout),
                   'redis-incorrect-password-denied')
        self.check(command(new, 'EVAL', "return redis.call('INCR',KEYS[1])", '1', 'compat:counter') == '2',
                   'redis-new-authenticated-lua-counter')
        expected = snapshot(new)
        self.run(['docker', 'restart', '--time', '15', new])
        self.wait(lambda: command(new, 'PING'), 'redis restart')
        self.check(snapshot(new) == expected, 'redis-new-state-survives-restart')
        self.stop(new)
        cold_data = self.volume('redis-old-cold')
        self.restore(cold_data, old_archive)
        cold = server('redis-old-cold', 'redisOld', cold_data)
        self.check(snapshot(cold) == baseline, 'redis-old-backup-cold-restores-on-exact-old-server',
                   archiveSha256=hashlib.sha256(old_archive).hexdigest())
        self.stop(cold)

    async def nats(self):
        import nats
        self.check(importlib.metadata.version('nats-py') == self.policy['probeOnlyClient']['version'],
                   'nats-official-probe-client-version')
        data = self.volume('nats-data')
        def server(suffix, image, volume):
            identity = self.create(suffix, image, data=[(volume, '/data')], ports=[4222],
                                   command=['--jetstream', '--store_dir=/data', '--user=fixture',
                                            '--pass=' + self.password])
            self.start(identity)
            return identity
        async def connect(identity, password=None, errors=None):
            async def error_cb(error):
                if errors is not None:
                    errors.append(str(error))
            return await nats.connect(servers=['nats://127.0.0.1:' + str(self.port(identity, 4222))],
                                      user='fixture', password=password or self.password,
                                      allow_reconnect=False, max_reconnect_attempts=0,
                                      connect_timeout=2, error_cb=error_cb)
        async def ready(identity):
            deadline = time.monotonic() + 30
            while True:
                try:
                    return await connect(identity)
                except Exception:
                    if time.monotonic() >= deadline:
                        raise
                    await asyncio.sleep(0.2)
        async def api(client, subject, body=None):
            message = await client.request(subject, json.dumps(body or {}).encode(), timeout=3)
            value = json.loads(message.data)
            if value.get('error'):
                raise RuntimeError('JetStream API rejected the fixture: ' + json.dumps(value['error']))
            return value
        async def consumer(client):
            return await api(client, '$JS.API.CONSUMER.INFO.COMPAT.WORK')
        async def pull(client, expected):
            # Pull replies retain the stored message's original subject. The
            # normal request multiplexer routes by inbox subject, so use the
            # official client's one-shot SID-based request for this endpoint.
            message = await client.request('$JS.API.CONSUMER.MSG.NEXT.COMPAT.WORK',
                                           b'{"batch":1,"expires":2000000000}', timeout=3, old_style=True)
            if message.data != expected or not message.reply.startswith('$JS.ACK.'):
                raise RuntimeError('Durable pull payload or acknowledgement subject changed.')
            self.check(message.subject == 'compat.values',
                       'nats-pull-retains-original-subject-' + expected.decode())
            await client.request(message.reply, b'+ACK', timeout=3)
        old = server('nats-old', 'natsOld', data)
        client = await ready(old)
        try:
            await api(client, '$JS.API.STREAM.CREATE.COMPAT', {'name': 'COMPAT', 'subjects': ['compat.values'],
                      'storage': 'file', 'retention': 'limits', 'num_replicas': 1,
                      'max_msgs': 10, 'max_bytes': 1048576, 'max_msg_size': 65536})
            await api(client, '$JS.API.CONSUMER.CREATE.COMPAT.WORK', {'stream_name': 'COMPAT',
                      'config': {'durable_name': 'WORK', 'ack_policy': 'explicit', 'deliver_policy': 'all',
                                 'replay_policy': 'instant'}})
            for index, payload in enumerate([b'fixture-one', b'fixture-two'], 1):
                ack = json.loads((await client.request('compat.values', payload, timeout=3)).data)
                self.check(ack.get('stream') == 'COMPAT' and ack.get('seq') == index,
                           'nats-old-publish-sequence-' + str(index))
            await pull(client, b'fixture-one')
            info = await consumer(client)
            self.check(info['ack_floor']['stream_seq'] == 1 and info['num_pending'] == 1,
                       'nats-old-durable-ack-floor-and-pending')
        finally:
            await client.close()
        self.stop(old)
        old_archive = self.archive(data)
        new = server('nats-new', 'nats', data)
        client = await ready(new)
        try:
            info = await consumer(client)
            self.check(info['ack_floor']['stream_seq'] == 1 and info['num_pending'] == 1,
                       'nats-old-filestore-and-durable-state-open-on-new-server')
            await pull(client, b'fixture-two')
            ack = json.loads((await client.request('compat.values', b'fixture-three', timeout=3)).data)
            self.check(ack.get('seq') == 3, 'nats-new-sequence-continues-at3')
            await pull(client, b'fixture-three')
        finally:
            await client.close()
        errors = []
        rejected = False
        connected = False
        try:
            invalid = await connect(new, password='wrong-fixture-password', errors=errors)
            connected = True
            await invalid.close()
        except Exception as error:
            rejected = 'authorization' in str(error).lower() or 'authentication' in str(error).lower()
        self.check(not connected and (rejected or any('authorization' in x.lower() or 'authentication' in x.lower() for x in errors)),
                   'nats-incorrect-password-explicitly-denied')
        self.run(['docker', 'restart', '--time', '15', new])
        client = await ready(new)
        try:
            info = await consumer(client)
            stream = await api(client, '$JS.API.STREAM.INFO.COMPAT')
            self.check(info['ack_floor']['stream_seq'] == 3 and info['num_ack_pending'] == 0 and
                       stream['state']['last_seq'] == 3, 'nats-sequence-and-acked-consumer-survive-restart')
        finally:
            await client.close()
        self.stop(new)
        cold_data = self.volume('nats-old-cold')
        self.restore(cold_data, old_archive)
        cold = server('nats-old-cold', 'natsOld', cold_data)
        client = await ready(cold)
        try:
            info = await consumer(client)
            self.check(info['ack_floor']['stream_seq'] == 1 and info['num_pending'] == 1,
                       'nats-old-backup-cold-restores-on-exact-old-server',
                       archiveSha256=hashlib.sha256(old_archive).hexdigest())
            await pull(client, b'fixture-two')
        finally:
            await client.close()
        self.stop(cold)

    def mailpit(self):
        def server(suffix):
            identity = self.create(suffix, 'mailpit', ports=[1025, 8025], tmpfs=['/data:size=67108864,mode=0700'],
                                   environment={'MP_DATABASE': '/data/mailpit.db', 'MP_MAX_MESSAGES': '500',
                                                'MP_DISABLE_VERSION_CHECK': 'true'})
            self.start(identity)
            self.wait(lambda: request(identity, '/api/v1/messages'), suffix)
            return identity
        def request(identity, path):
            with urllib.request.urlopen('http://127.0.0.1:' + str(self.port(identity, 8025)) + path, timeout=3) as response:
                raw = response.read(2_000_001)
            if len(raw) > 2_000_000:
                raise RuntimeError('Unexpected Mailpit response size.')
            return json.loads(raw)
        identity = server('mailpit')
        self.check(request(identity, '/api/v1/messages')['messages'] == [], 'mailpit-starts-with-empty-tmpfs')
        message = EmailMessage()
        message['From'], message['To'] = 'fixture@example.invalid', 'recipient@example.invalid'
        message['Subject'] = self.owner
        code = base64.b64encode(b'fixture-only-verification-code-32').decode()
        message.set_content('Use this one-time verification code: ' + code + '\n')
        def smtp_ready():
            with smtplib.SMTP('127.0.0.1', self.port(identity, 1025), timeout=3) as smtp:
                if smtp.noop()[0] != 250:
                    raise RuntimeError('Mailpit SMTP readiness was not accepted.')
        self.wait(smtp_ready, 'Mailpit SMTP')
        with smtplib.SMTP('127.0.0.1', self.port(identity, 1025), timeout=5) as smtp:
            smtp.send_message(message)
        def captured():
            found = [x for x in request(identity, '/api/v1/messages')['messages'] if x['Subject'] == self.owner]
            if len(found) != 1:
                raise RuntimeError('Expected exactly one captured fixture email.')
            return found[0]
        summary = self.wait(captured, 'Mailpit capture')
        self.check(any(x['Address'] == 'recipient@example.invalid' for x in summary['To']),
                   'mailpit-recipient-and-subject-preserved')
        detail = request(identity, '/api/v1/message/' + summary['ID'])
        self.check('Use this one-time verification code: ' + code in detail['Text'],
                   'mailpit-verification-body-preserved')
        self.run(['docker', 'exec', identity, '/mailpit', 'readyz'])
        self.stop(identity)
        fresh = server('mailpit-recreated')
        self.check(request(fresh, '/api/v1/messages')['messages'] == [],
                   'mailpit-recreate-retains-intended-ephemeral-mail-design')
        self.stop(fresh)

    def archives(self):
        data = self.volume('archive-source')
        self.utility(data, "mkdir -p /state/state/nested; printf fixture > /state/state/rows.bin; "
                     "printf fixture-text > /state/state/nested/file.txt; ln -s nested/file.txt /state/state/link; "
                     "chown -R 70:70 /state/state; chmod 640 /state/state/rows.bin; chmod 600 /state/state/nested/file.txt")
        query = "stat -c '%u:%g:%a' /state/state/rows.bin /state/state/nested/file.txt; " \
                "sha256sum /state/state/rows.bin /state/state/nested/file.txt; readlink /state/state/link"
        baseline = self.utility(data, query)
        old = self.archive(data, 'archiveOld')
        fresh = self.volume('archive-new-reader')
        self.restore(fresh, old, 'archive')
        self.check(self.utility(fresh, query) == baseline, 'old-tar-archive-restores-with-new-tool-preserving-uid-mode-bytes-link')
        new = self.archive(fresh, 'archive')
        legacy = self.volume('archive-old-reader')
        self.restore(legacy, new, 'archiveOld')
        self.check(self.utility(legacy, query, 'archiveOld') == baseline,
                   'new-tar-archive-remains-readable-by-old-tool',
                   oldArchiveSha256=hashlib.sha256(old).hexdigest(), newArchiveSha256=hashlib.sha256(new).hexdigest())

    def cleanup(self):
        errors = []
        for identity in reversed(self.containers):
            try:
                self.owned('container', identity)
                logs = self.run(['docker', 'logs', identity], check=False)
                (self.destination / (identity[:12] + '.log')).write_text(
                    (logs.stdout + logs.stderr).replace(self.password, '[REDACTED]')[-24000:])
                self.run(['docker', 'rm', '--force', '--volumes', identity])
            except Exception as error:
                errors.append(str(error).replace(self.password, '[REDACTED]'))
        for volume in reversed(self.volumes):
            try:
                self.owned('volume', volume)
                self.run(['docker', 'volume', 'rm', volume])
            except Exception as error:
                errors.append(str(error).replace(self.password, '[REDACTED]'))
        if self.network_created:
            try:
                if self.owned('network', self.network).get('Containers'):
                    raise RuntimeError('Owned network still has containers.')
                self.run(['docker', 'network', 'rm', self.network])
            except Exception as error:
                errors.append(str(error).replace(self.password, '[REDACTED]'))
        return {'containersCreated': len(self.containers), 'volumesCreated': len(self.volumes),
                'networkCreated': self.network_created, 'allOwnedResourcesRemoved': not errors, 'errors': errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('all', 'nats'), default='all')
    options = parser.parse_args()
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    expected = os.environ.get('EXPECTED_SOURCE_SHA', '')
    if re.fullmatch(r'[a-f0-9]{40}', expected) is None or actual != expected:
        raise RuntimeError('Probe source does not match the reviewed immutable commit.')
    policy = json.loads(Path('.gma/preview-state-compatibility-review.json').read_text())
    probe = Probe(policy)
    required_phases = ['redis', 'nats', 'mailpit', 'archives'] if options.phase == 'all' else ['nats']
    report = {'schemaVersion': 1, 'sourceCommit': actual,
              'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'owner': probe.owner, 'subjects': policy['images'], 'probeOnlyClient': policy['probeOnlyClient'],
              'observations': probe.observations, 'phases': [], 'passed': False,
              'requiredPhases': required_phases, 'fullQualification': options.phase == 'all',
              'scope': policy['scope'] + (' NATS-only repaired-source evidence; other three groups are not rerun or requalified here.'
                                         if options.phase == 'nats' else '')}
    try:
        subjects = policy['images'] if options.phase == 'all' else {
            name: policy['images'][name] for name in ('natsOld', 'nats', 'archive')}
        for subject in subjects.values():
            probe.run(['docker', 'pull', '--platform', 'linux/amd64', subject['image']], timeout=180)
            actual_image = probe.inspect('image', subject['image'])
            if (actual_image['Id'] != subject['configDigest'] or actual_image['Os'] != 'linux' or
                    actual_image['Architecture'] != 'amd64'):
                raise RuntimeError('Fixture image configuration or platform changed.')
        probe.run(['docker', 'network', 'create', '--label', LABEL + '=' + probe.owner, probe.network])
        probe.network_created = True
        probe.owned('network', probe.network)
        for name, operation in [('redis', probe.redis), ('nats', lambda: asyncio.run(probe.nats())),
                                ('mailpit', probe.mailpit), ('archives', probe.archives)]:
            if name not in required_phases:
                continue
            try:
                operation()
                report['phases'].append({'name': name, 'passed': True})
            except Exception as error:
                report['phases'].append({'name': name, 'passed': False, 'failureType': type(error).__name__,
                                         'failure': str(error).replace(probe.password, '[REDACTED]'),
                                         'failureTrace': traceback.format_exc().replace(probe.password, '[REDACTED]')[-5000:]})
        report['passed'] = len(report['phases']) == len(required_phases) and all(x['passed'] for x in report['phases'])
    finally:
        report['cleanup'] = probe.cleanup()
        report['passed'] = report['passed'] and report['cleanup']['allOwnedResourcesRemoved']
        report['observationsPassed'] = len(probe.observations)
        (probe.destination / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({key: report[key] for key in ['passed', 'phases', 'observationsPassed', 'cleanup']}))
    if not report['passed']:
        raise SystemExit('State compatibility requires review; raw observations and logs retained.')


if __name__ == '__main__':
    main()
