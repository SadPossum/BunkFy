#!/usr/bin/env python3
"""Probe one immutable S3 fixture on a disposable runner, without application builds."""

import datetime
import gzip
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import secrets
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zlib


IMAGE = 'pgsty/silo:RELEASE.2026-10-26T00-00-00Z@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7'
SOURCE = 'c3ad836aed0d8a7d23c2e44a5eaa3009d08525e3'
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def docker(*arguments, required=True):
    result = subprocess.run(['docker', *arguments], capture_output=True, text=True, timeout=120)
    if required and result.returncode:
        diagnostic = result.stderr.splitlines()[0][:300] if result.stderr else 'no daemon diagnostic'
        raise RuntimeError('Docker fixture command failed: ' + arguments[0] + ': ' + diagnostic)
    return result.stdout.strip()


def request(endpoint, key, password, method, path, body=b'', headers=None, signed=True, bad_signature=False, timeout=15):
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
        query = urllib.parse.urlencode(sorted(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)), quote_via=urllib.parse.quote)
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
        with HTTP.open(value, timeout=timeout) as response:
            return response.status, response.read(1024 * 1024), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(1024 * 1024), dict(error.headers)


def select_result(body):
    if body.startswith(b'<?xml') or body.startswith(b'<Error>'):
        return ET.fromstring(body).findtext('Code'), b''
    records, error, offset = [], None, 0
    while offset < len(body):
        total, header_length, checksum = struct.unpack('>III', body[offset:offset + 12])
        frame = body[offset:offset + total]
        if (total < 16 or len(frame) != total or header_length > total - 16
                or zlib.crc32(frame[:8]) != checksum
                or zlib.crc32(frame[:-4]) != struct.unpack('>I', frame[-4:])[0]):
            raise RuntimeError('Invalid S3 Select event stream frame.')
        position, headers = 12, {}
        while position < 12 + header_length:
            length = frame[position]; position += 1
            name = frame[position:position + length].decode(); position += length
            kind = frame[position]; position += 1
            if kind != 7:
                raise RuntimeError('Unexpected S3 Select header type.')
            length = struct.unpack('>H', frame[position:position + 2])[0]; position += 2
            headers[name] = frame[position:position + length].decode(); position += length
        if headers.get(':message-type') == 'error':
            error = headers.get(':error-code')
        if headers.get(':event-type') == 'Records':
            records.append(frame[12 + header_length:-4])
        offset += total
    return error, b''.join(records)


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
                   '--memory', '768m', '--memory-swap', '768m', '--cpus', '1', '--pids-limit', '128',
                   '--env-file', str(environment),
                   '--mount', 'type=volume,source=' + volume + ',target=/data',
                   IMAGE, 'server', '/data', '--console-address', ':9001')
            def private_endpoint():
                networks = json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Networks}}', name))
                if set(networks) != {network}:
                    raise RuntimeError('Fixture must use only its dedicated internal network.')
                address = ipaddress.ip_address(networks[network]['IPAddress'])
                if address.version != 4 or not address.is_private or address.is_loopback:
                    raise RuntimeError('Fixture address must be private IPv4 on its owned bridge.')
                published = json.loads(docker('inspect', '--format', '{{json .HostConfig.PortBindings}}', name))
                if published:
                    raise RuntimeError('Storage fixture must not publish any host ports.')
                return 'http://' + str(address) + ':9000'
            endpoint = private_endpoint()
            receipt['networkIsolation'] = 'Dedicated internal bridge, no published host ports; requests bypass external proxies.'

            def ready():
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    try:
                        status, _, _ = request(endpoint, key, password, 'GET', '/minio/health/ready', signed=False,
                                               timeout=min(2, max(0.1, deadline - time.monotonic())))
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

            # Exercise the actual CVE path in the pinned binary. Payloads stay
            # below 2 MiB, with a hard container memory/CPU bound and no shared data.
            for label, serialization, expression, small, large in (
                ('CSV', '<CSV><FileHeaderInfo>NONE</FileHeaderInfo></CSV>', 'SELECT s._1 FROM S3Object s', b'fixture-sentinel\n', b'a' * ((1 << 20) + 65536)),
                ('JSON Lines', '<JSON><Type>LINES</Type></JSON>', 'SELECT s.name FROM S3Object s', b'{"name":"fixture-sentinel"}\n', b'{"name":"' + b'a' * ((1 << 20) + 65536) + b'"}'),
                ('gzip CSV', '<CSV><FileHeaderInfo>NONE</FileHeaderInfo></CSV>', 'SELECT s._1 FROM S3Object s', b'fixture-sentinel\n', b'a' * ((1 << 20) + 65536)),
            ):
                compression = 'GZIP' if label == 'gzip CSV' else 'NONE'
                select_path = bucket + '/record-probe'
                query = ('<SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                         '<Expression>' + expression + '</Expression><ExpressionType>SQL</ExpressionType>'
                         '<InputSerialization><CompressionType>' + compression + '</CompressionType>' + serialization
                         + '</InputSerialization><OutputSerialization><CSV/></OutputSerialization></SelectObjectContentRequest>').encode()
                for oversized, data in ((False, small), (True, large)):
                    if compression == 'GZIP':
                        data = gzip.compress(data)
                    expect(label + ' probe object write', 'PUT', select_path, 200, body=data)
                    status, response, _ = request(endpoint, key, password, 'POST', select_path + '?select=&select-type=2', body=query)
                    error, records = select_result(response)
                    if oversized:
                        if status not in (200, 400) or error != 'OverMaxRecordSize':
                            raise RuntimeError(label + ' did not reject the oversized record with its bounded error.')
                    elif status != 200 or error is not None or records != b'fixture-sentinel\n':
                        raise RuntimeError(label + ' positive control did not select the expected record.')
                    receipt['observations'].append({'case': label + (' oversized record rejected' if oversized else ' positive Select control'),
                                                    'httpStatus': status, 'errorCode': error, 'inputBytes': len(data)})
                    expect(label + ' service remains ready', 'GET', '/minio/health/ready', 200, signed=False)
                expect(label + ' probe object deletion', 'DELETE', select_path, 204)
            receipt['recordLimitScope'] = 'Three positive and three bounded oversized-record binary regressions plus exact-source review; not a memory benchmark, distributed-storage acceptance or scanner clearance.'
            docker('restart', name)
            endpoint = private_endpoint()
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
        try:
            state = json.loads(docker('inspect', '--format', '{{json .State}}', name))
            receipt['failedContainerState'] = {field: state[field] for field in ('Status', 'ExitCode', 'OOMKilled')}
        except Exception:
            pass
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
