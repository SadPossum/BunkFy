#!/usr/bin/env python3
"""Qualify disposable PostgreSQL old-data/nonroot/restore behavior without app builds."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
import uuid


OLD_IMAGE = 'postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa'
NEW_IMAGE = 'postgres:17.11-alpine3.23@sha256:05aa77262db9277fde6374bb2f901c9604b8a9373029e1a7993440c6aae48736'
NEW_CONFIG = 'sha256:63fb01dbab2f21a30c1188f6b05319df39b786a5845a5541299ed0dc3ed5bc69'
HELPER_SHA256 = '52c8749d0142edd234e9d6bd5237dff2d81e71f43537e2f4f66f75dd4b243dd0'
LABEL = 'com.bunkfy.review.owner'


def main():
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    expected = os.environ.get('EXPECTED_SOURCE_SHA', '')
    if re.fullmatch(r'[a-f0-9]{40}', expected) is None or expected != actual:
        raise RuntimeError('Reviewed source identity does not match.')
    destination = Path('artifacts/postgres-context')
    destination.mkdir(parents=True, exist_ok=True)
    owner = 'bunkfy-pg-review-' + uuid.uuid4().hex
    password = secrets.token_hex(32)
    containers, volumes, observations = [], [], []
    report = {'schemaVersion': 1, 'sourceCommit': actual, 'owner': owner,
              'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'oldImage': OLD_IMAGE, 'newImage': NEW_IMAGE, 'newImageConfig': NEW_CONFIG,
              'observations': observations, 'passed': False,
              'scope': 'Disposable synthetic PostgreSQL data only. Same-major old-volume upgrade, '
                       'nonroot startup/restart, logical restore and helper execution context. '
                       'Not whole-app data migration/recovery, real deployment, or blanket image approval.'}

    def run(arguments, *, check=True, binary=False, input_data=None, timeout=90):
        result = subprocess.run(arguments, capture_output=True, text=not binary,
                                input=input_data, timeout=timeout)
        if check and result.returncode:
            error = result.stderr.decode(errors='replace') if binary else result.stderr
            raise RuntimeError('Disposable probe command failed: ' + arguments[0] + ' ' +
                               arguments[1] + ': ' + error.replace(password, '[REDACTED]')[-1800:])
        return result

    def inspect(kind, name):
        result = json.loads(run(['docker', kind, 'inspect', name]).stdout)
        if len(result) != 1:
            raise RuntimeError('Unexpected disposable resource identity.')
        return result[0]

    def owned(kind, name):
        value = inspect(kind, name)
        labels = value.get('Labels') if kind == 'volume' else value['Config'].get('Labels')
        if not labels or labels.get(LABEL) != owner:
            raise RuntimeError('Refusing to operate on an unowned Docker resource.')
        return value

    def volume(suffix):
        name = owner + '-' + suffix
        run(['docker', 'volume', 'create', '--label', LABEL + '=' + owner, name])
        volumes.append(name)
        owned('volume', name)
        return name

    def create(suffix, image, data, nonroot):
        name = owner + '-' + suffix
        args = ['docker', 'create', '--name', name, '--label', LABEL + '=' + owner,
                '--network', 'none', '--memory', '512m', '--memory-swap', '512m', '--cpus', '1',
                '--pids-limit', '128', '--security-opt', 'no-new-privileges:true',
                '--mount', 'type=volume,src=' + data + ',dst=/var/lib/postgresql/data',
                '--env', 'POSTGRES_DB=fixture', '--env', 'POSTGRES_USER=fixture',
                '--env', 'POSTGRES_PASSWORD=' + password]
        if nonroot:
            args += ['--user', '70:70', '--read-only', '--cap-drop', 'ALL',
                     '--tmpfs', '/var/run/postgresql:size=8388608,uid=70,gid=70,mode=3775',
                     '--tmpfs', '/tmp:size=33554432,mode=1777']
        args.append(image)
        identity = run(args).stdout.strip()
        if re.fullmatch(r'[a-f0-9]{64}', identity) is None:
            raise RuntimeError('Unexpected disposable container identity.')
        containers.append(identity)
        owned('container', identity)
        return identity

    def sql(identity, query, *, secret=None, check=True):
        owned('container', identity)
        return run(['docker', 'exec', '--env', 'PGPASSWORD=' + (secret or password), identity,
                    'psql', '-h', '127.0.0.1', '-U', 'fixture', '-d', 'fixture', '-X', '-A', '-t',
                    '-v', 'ON_ERROR_STOP=1', '-c', query], check=check)

    def ready(identity):
        run(['docker', 'start', identity])
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            if sql(identity, 'SELECT 1', check=False).returncode == 0:
                return
            if not owned('container', identity)['State']['Running']:
                raise RuntimeError('Disposable PostgreSQL exited during startup.')
            time.sleep(0.3)
        raise RuntimeError('Disposable PostgreSQL readiness deadline exceeded.')

    def snapshot(identity):
        rows = sql(identity, "SELECT json_agg(t ORDER BY id)::text FROM fixture_rows t").stdout.strip()
        sequence = sql(identity, 'SELECT last_value FROM fixture_rows_id_seq').stdout.strip()
        return {'rows': json.loads(rows), 'sequence': int(sequence)}

    def context(identity, label):
        value = owned('container', identity)
        if (value['Image'] != NEW_CONFIG or value['Config']['User'] != '70:70' or
                not value['HostConfig']['ReadonlyRootfs'] or value['HostConfig']['NetworkMode'] != 'none' or
                value['HostConfig']['CapDrop'] != ['ALL'] or
                'no-new-privileges:true' not in value['HostConfig']['SecurityOpt'] or
                sorted(mount['Destination'] for mount in value['Mounts'] if mount['Type'] == 'volume') !=
                ['/var/lib/postgresql/data'] or any(mount['Type'] == 'bind' for mount in value['Mounts'])):
            raise RuntimeError('Nonroot startup profile or image identity changed.')
        status = run(['docker', 'exec', identity, 'cat', '/proc/1/status']).stdout
        uid = re.search(r'^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', status, re.MULTILINE)
        gid = re.search(r'^Gid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', status, re.MULTILINE)
        if (not uid or set(uid.groups()) != {'70'} or not gid or set(gid.groups()) != {'70'} or
                re.search(r'^CapEff:\s+0+$', status, re.MULTILINE) is None or
                re.search(r'^NoNewPrivs:\s+1$', status, re.MULTILINE) is None):
            raise RuntimeError('Actual database process credentials or restrictions changed.')
        files = []
        for path in ['/etc/passwd', '/etc/group', '/usr/local/bin/gosu']:
            attributes = run(['docker', 'exec', identity, 'stat', '-c', '%u:%g:%a:%s', path]).stdout.strip()
            user, group, mode, size = attributes.split(':')
            if user != '0' or group != '0' or int(mode, 8) & 0o022 or int(size) > 2_000_000:
                raise RuntimeError('Helper trust-boundary file ownership or bounds changed.')
            content = run(['docker', 'exec', identity, 'cat', path], binary=True).stdout
            if len(content) != int(size):
                raise RuntimeError('Helper trust-boundary file is incomplete.')
            file_hash = hashlib.sha256(content).hexdigest()
            if path.endswith('/gosu') and file_hash != HELPER_SHA256:
                raise RuntimeError('Actual helper binary changed.')
            if path in ['/etc/passwd', '/etc/group'] and len(content) > 65_536:
                raise RuntimeError('Unexpected user/group database size.')
            files.append({'path': path, 'uid': user, 'gid': group, 'mode': mode,
                          'size': len(content), 'sha256': file_hash})
        run(['docker', 'exec', identity, 'sh', '-c',
             'test ! -w /etc/passwd && test ! -w /etc/group && test ! -w /usr/local/bin/gosu'])
        entrypoint = run(['docker', 'exec', identity, 'cat', '/usr/local/bin/docker-entrypoint.sh']).stdout
        (destination / 'actual-image-entrypoint.txt').write_text(entrypoint)
        if 'exec gosu postgres' not in entrypoint:
            raise RuntimeError('Expected official privilege-drop entrypoint was not observed.')
        observations.append({'case': label, 'passed': True, 'uid': '70', 'gid': '70',
                             'effectiveCapabilities': '0', 'noNewPrivileges': True,
                             'rootFilesystemReadOnly': True, 'bindMounts': 0,
                             'helperInputFiles': files,
                             'entrypointSha256': hashlib.sha256(entrypoint.encode()).hexdigest()})

    try:
        for image in [OLD_IMAGE, NEW_IMAGE]:
            run(['docker', 'pull', '--platform', 'linux/amd64', image], timeout=180)
        if inspect('image', NEW_IMAGE)['Id'] != NEW_CONFIG:
            raise RuntimeError('New image configuration identity changed.')
        data = volume('old-data')
        old = create('old', OLD_IMAGE, data, False)
        ready(old)
        sql(old, "CREATE TABLE fixture_rows (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                 "name text NOT NULL UNIQUE, payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object')); "
                 "CREATE INDEX fixture_payload ON fixture_rows USING gin(payload); "
                 "INSERT INTO fixture_rows(name,payload) VALUES "
                 "('booking-one','{\"quantity\":2,\"tenant\":\"fixture-only\"}'), "
                 "('booking-two','{\"quantity\":3,\"tenant\":\"fixture-only\"}');")
        baseline = snapshot(old)
        dump = run(['docker', 'exec', '--env', 'PGPASSWORD=' + password, old, 'pg_dump',
                    '-h', '127.0.0.1', '-U', 'fixture', '-d', 'fixture', '--format=custom',
                    '--no-owner', '--no-acl'], binary=True).stdout
        if not dump.startswith(b'PGDMP') or len(dump) < 500:
            raise RuntimeError('Old logical backup is missing or incomplete.')
        report['oldLogicalBackup'] = {'bytes': len(dump), 'sha256': hashlib.sha256(dump).hexdigest()}
        run(['docker', 'stop', '--time', '20', old])
        upgraded = create('upgraded', NEW_IMAGE, data, True)
        ready(upgraded)
        if snapshot(upgraded) != baseline:
            raise RuntimeError('Old data changed during same-major nonroot upgrade.')
        context(upgraded, 'existing-17.5-data-upgrades-under-uid70')
        if sql(upgraded, 'SELECT 1', secret='wrong-fixture-password', check=False).returncode == 0:
            raise RuntimeError('Incorrect database password was accepted.')
        observations.append({'case': 'incorrect-password-denied', 'passed': True})
        run(['docker', 'restart', '--time', '20', upgraded])
        deadline = time.monotonic() + 60
        while sql(upgraded, 'SELECT 1', check=False).returncode:
            if time.monotonic() >= deadline:
                raise RuntimeError('Restart readiness deadline exceeded.')
            time.sleep(0.3)
        if snapshot(upgraded) != baseline:
            raise RuntimeError('Persistent state changed after nonroot restart.')
        context(upgraded, 'nonroot-upgraded-data-survives-restart')
        fresh = create('fresh', NEW_IMAGE, volume('fresh-data'), True)
        ready(fresh)
        context(fresh, 'fresh-volume-initializes-under-uid70')
        owned('container', fresh)
        run(['docker', 'exec', '-i', '--env', 'PGPASSWORD=' + password, fresh, 'pg_restore',
             '-h', '127.0.0.1', '-U', 'fixture', '-d', 'fixture', '--exit-on-error',
             '--no-owner', '--no-privileges'], binary=True, input_data=dump)
        if snapshot(fresh) != baseline:
            raise RuntimeError('Old logical backup did not restore into the new nonroot profile.')
        next_id = sql(fresh, "INSERT INTO fixture_rows(name,payload) VALUES ('booking-three','{}') RETURNING id").stdout.splitlines()[0]
        if next_id != '3':
            raise RuntimeError('Restored identity sequence did not continue correctly.')
        observations.append({'case': 'old-logical-backup-restores-and-next-identity-is3', 'passed': True})
        report.update(passed=True, observationsPassed=len(observations))
    except BaseException as error:
        report.update(failureType=type(error).__name__, failure=str(error).replace(password, '[REDACTED]'))
        raise
    finally:
        cleanup_errors = []
        for identity in reversed(containers):
            try:
                owned('container', identity)
                logs = run(['docker', 'logs', identity], check=False)
                (destination / (identity[:12] + '.log')).write_text((logs.stdout + logs.stderr).replace(password, '[REDACTED]')[-32000:])
                run(['docker', 'rm', '--force', '--volumes', identity])
            except Exception as error:
                cleanup_errors.append(str(error).replace(password, '[REDACTED]'))
        for name in reversed(volumes):
            try:
                owned('volume', name)
                run(['docker', 'volume', 'rm', name])
            except Exception as error:
                cleanup_errors.append(str(error).replace(password, '[REDACTED]'))
        report['cleanup'] = {'containersCreated': len(containers), 'volumesCreated': len(volumes),
                             'allOwnedResourcesRemoved': not cleanup_errors, 'errors': cleanup_errors}
        (destination / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({key: report.get(key) for key in ['passed', 'observationsPassed', 'cleanup', 'failureType']}))
        if cleanup_errors:
            raise RuntimeError('Disposable PostgreSQL probe cleanup failed; evidence retained.')


if __name__ == '__main__':
    main()
