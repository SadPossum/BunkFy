#!/usr/bin/env python3
"""Probe one immutable S3 fixture on a disposable runner, without application builds."""

import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


IMAGE = 'pgsty/silo:RELEASE.2026-10-26T00-00-00Z@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7'
SOURCE = 'c3ad836aed0d8a7d23c2e44a5eaa3009d08525e3'


def docker(*arguments, required=True):
    result = subprocess.run(['docker', *arguments], capture_output=True, text=True, timeout=120)
    if required and result.returncode:
        raise RuntimeError('Docker fixture command failed: ' + arguments[0])
    return result.stdout.strip()


def request(endpoint, key, password, method, path, body=b'', headers=None, signed=True, bad_signature=False):
    headers = dict(headers or {})
    if signed:
        now = datetime.datetime.now(datetime.timezone.utc)
        date, stamp = now.strftime('%Y%m%d'), now.strftime('%Y%m%dT%H%M%SZ')
        payload = hashlib.sha256(body).hexdigest()
        host = urllib.parse.urlsplit(endpoint).netloc
        headers.update({'Host': host, 'x-amz-date': stamp, 'x-amz-content-sha256': payload})
        signed_headers = 'host;x-amz-content-sha256;x-amz-date'
        canonical_headers = 'host:' + host + '\nx-amz-content-sha256:' + payload + '\nx-amz-date:' + stamp + '\n'
        parsed = urllib.parse.urlsplit(path)
        query = urllib.parse.urlencode(sorted(urllib.parse.parse_qsl(parsed.query)), quote_via=urllib.parse.quote)
        canonical = '\n'.join([method, parsed.path, query, canonical_headers, signed_headers, payload])
        scope = date + '/us-east-1/s3/aws4_request'
        signing = ('AWS4' + password).encode()
        for value in (date, 'us-east-1', 's3', 'aws4_request'):
            signing = hmac.new(signing, value.encode(), hashlib.sha256).digest()
        message = 'AWS4-HMAC-SHA256\n' + stamp + '\n' + scope + '\n' + hashlib.sha256(canonical.encode()).hexdigest()
        signature = hmac.new(signing, message.encode(), hashlib.sha256).hexdigest()
        if bad_signature:
            signature = ('0' if signature[0] != '0' else '1') + signature[1:]
        headers['Authorization'] = 'AWS4-HMAC-SHA256 Credential=' + key + '/' + scope + ', SignedHeaders=' + signed_headers + ', Signature=' + signature
    value = urllib.request.Request(endpoint + path, data=body if method in ('PUT', 'POST') else None,
                                   method=method, headers=headers)
    try:
        with urllib.request.urlopen(value, timeout=15) as response:
            return response.status, response.read(1024 * 1024), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(1024 * 1024), dict(error.headers)


def main():
    os.umask(0o077)
    nonce = uuid.uuid4().hex[:16]
    name, network, volume = ['bunk-storage-' + label + '-' + nonce for label in ('server', 'net', 'data')]
    output = Path('artifacts/silo-runtime.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    receipt = {'schemaVersion': 1, 'image': IMAGE, 'expectedSourceRevision': SOURCE,
               'purpose': 'Isolated engineering S3 compatibility; no existing data or Production admission.',
               'observations': [], 'result': 'failed', 'cleanup': {}}
    try:
        labels = json.loads(docker('image', 'inspect', '--format', '{{json .Config.Labels}}', IMAGE))
        if labels.get('org.opencontainers.image.revision') != SOURCE:
            raise RuntimeError('Provider image does not bind the reviewed source revision.')
        receipt['actualSourceRevision'] = labels['org.opencontainers.image.revision']
        with tempfile.TemporaryDirectory(prefix='bunk-storage-private-') as temporary:
            environment = Path(temporary) / 'storage.env'
            key, password = secrets.token_hex(12), secrets.token_hex(32)
            environment.write_text('MINIO_ROOT_USER=' + key + '\nMINIO_ROOT_PASSWORD=' + password + '\n')
            docker('network', 'create', '--internal', network)
            docker('volume', 'create', volume)
            docker('run', '--detach', '--name', name, '--network', network,
                   '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                   '--env-file', str(environment), '--publish', '127.0.0.1::9000',
                   '--mount', 'type=volume,source=' + volume + ',target=/data',
                   IMAGE, 'server', '/data', '--console-address', ':9001')
            binding = docker('port', name, '9000/tcp')
            match = re.fullmatch(r'127\.0\.0\.1:([0-9]+)', binding)
            if not match or int(match[1]) < 1024:
                raise RuntimeError('S3 must bind only to loopback on a dynamic unprivileged port.')
            endpoint = 'http://' + binding

            def ready():
                for _ in range(60):
                    try:
                        status, _, _ = request(endpoint, key, password, 'GET', '/minio/health/ready', signed=False)
                        if status == 200:
                            return
                    except (OSError, urllib.error.URLError):
                        pass
                    time.sleep(1)
                raise RuntimeError('Storage readiness exceeded its bounded deadline.')

            def expect(label, method, path, status, **options):
                actual, body, headers = request(endpoint, key, password, method, path, **options)
                receipt['observations'].append({'case': label, 'expectedStatus': status, 'actualStatus': actual})
                if actual != status:
                    raise RuntimeError('S3 contract failed: ' + label + ' status ' + str(actual))
                return body, headers

            ready()
            bucket = '/bunk-fixture-' + nonce
            object_path = bucket + '/private-probe.bin'
            payload = secrets.token_bytes(4096)
            expect('readiness', 'GET', '/minio/health/ready', 200, signed=False)
            expect('liveness', 'GET', '/minio/health/live', 200, signed=False)
            expect('anonymous account listing denied', 'GET', '/', 403, signed=False)
            expect('create private bucket', 'PUT', bucket, 200)
            _, metadata = expect('signed private object put', 'PUT', object_path, 200, body=payload)
            etag = next((value for field, value in metadata.items() if field.lower() == 'etag'), None)
            if not etag:
                raise RuntimeError('S3 write omitted its entity tag.')
            body, _ = expect('signed exact object read', 'GET', object_path, 200)
            if body != payload:
                raise RuntimeError('S3 object bytes changed.')
            expect('anonymous object read denied', 'GET', object_path, 403, signed=False)
            expect('invalid signature denied', 'GET', object_path, 403, bad_signature=True)
            expect('signed object head', 'HEAD', object_path, 200)
            body, _ = expect('bounded range read', 'GET', object_path, 206, headers={'Range': 'bytes=0-31'})
            if body != payload[:32]:
                raise RuntimeError('S3 range bytes changed.')
            expect('wrong entity tag rejected', 'GET', object_path, 412, headers={'If-Match': '"wrong"'})
            body, _ = expect('matching entity tag read', 'GET', object_path, 200, headers={'If-Match': etag})
            if body != payload:
                raise RuntimeError('Conditional read bytes changed.')
            body, _ = expect('bounded prefix listing', 'GET', bucket + '?list-type=2&prefix=private-', 200)
            if b'private-probe.bin' not in body:
                raise RuntimeError('Prefix listing omitted the committed object.')
            docker('restart', name)
            ready()
            body, _ = expect('object survives provider restart', 'GET', object_path, 200)
            if body != payload:
                raise RuntimeError('S3 object did not survive provider restart.')
            expect('signed object deletion', 'DELETE', object_path, 204)
            expect('deleted object unavailable', 'GET', object_path, 404)
            expect('empty bucket deletion', 'DELETE', bucket, 204)
            environment.unlink()
        receipt['result'] = 'passed'
    except Exception as error:
        # Never retain raw environment, Authorization, object bytes or container logs.
        receipt['error'] = {'type': type(error).__name__, 'firstLine': str(error).splitlines()[0]}
    finally:
        docker('rm', '--force', name, required=False)
        docker('volume', 'rm', volume, required=False)
        docker('network', 'rm', network, required=False)
        try:
            docker('info', '--format', '{{.ServerVersion}}')
            receipt['cleanup']['containerRemoved'] = name not in docker('ps', '--all', '--format', '{{.Names}}').splitlines()
            receipt['cleanup']['volumeRemoved'] = volume not in docker('volume', 'ls', '--format', '{{.Name}}').splitlines()
            receipt['cleanup']['networkRemoved'] = network not in docker('network', 'ls', '--format', '{{.Name}}').splitlines()
            receipt['cleanup']['generatedEnvironmentRemoved'] = not environment.exists() if 'environment' in locals() else True
        except Exception:
            receipt['cleanup']['verificationFailed'] = True
        if len(receipt['cleanup']) != 4 or not all(receipt['cleanup'].values()):
            receipt['result'] = 'failed'
        output.write_text(json.dumps(receipt, indent=2) + '\n')
    if receipt['result'] != 'passed':
        raise RuntimeError('Storage fixture failed; see minimized evidence. No application qualification claimed.')
    print('Signed S3, denied private reads, restart persistence and cleanup passed.')


if __name__ == '__main__':
    main()
