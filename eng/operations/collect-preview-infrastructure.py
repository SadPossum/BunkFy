#!/usr/bin/env python3
"""Collect raw infrastructure scans and the actual tracked Compose PostgreSQL context."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'artifacts'


def run(arguments, *, env=None, check=True, binary=False, timeout=180):
    value = subprocess.run(arguments, env=env, capture_output=True, text=not binary, timeout=timeout)
    if check and value.returncode:
        # Compose/database diagnostics may contain generated credentials.
        raise RuntimeError('Infrastructure collection command failed: ' + arguments[0]
                           + ' (exit ' + str(value.returncode) + ')')
    return value


def inspect(kind, name):
    values = json.loads(run(['docker', kind, 'inspect', name]).stdout)
    if len(values) != 1:
        raise RuntimeError('Expected exactly one infrastructure resource.')
    return values[0]


def collect_context(profile, source):
    work = Path(tempfile.mkdtemp(prefix='bunkfy-infra-context-'))
    project = 'bunkfy-infra-' + uuid.uuid4().hex[:20]
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('BUNKFY_', 'COMPOSE_'))}
    environment.update(BUNKFY_COMPOSE_PROJECT_NAME=project, BUNKFY_VOLUME_PREFIX=project,
                       BUNKFY_INFRA_PROFILE='maintained')
    private_env = work / 'preview.env'
    # Test resource bounds only; service image, security and state contracts come
    # from the actual tracked Compose files, not a duplicated probe topology.
    limits = work / 'fixture-limits.json'
    limits.write_text(json.dumps({'services': {'postgres': {
        'mem_limit': '512m', 'memswap_limit': '512m', 'cpus': 1, 'pids_limit': 128}}}))
    compose = ['docker', 'compose', '--env-file', str(private_env), '-f',
               str(ROOT / 'deploy/preview/compose.yaml'), '-f', str(limits)]
    context = {'schemaVersion': 1, 'sourceCommit': source, 'image': profile['images']['postgres'],
               'imageConfigDigest': profile['configurationIds']['postgres'], 'passed': False, 'cleanup': {}}
    creation_attempted = False
    try:
        run(['pwsh', '-NoLogo', '-NoProfile', '-File', str(ROOT / 'eng/new-preview-env.ps1'),
             '-OutputPath', str(private_env)], env=environment)
        definition = json.loads(run(compose + ['config', '--format', 'json'], env=environment).stdout)
        pg = definition['services']['postgres']
        if (definition['name'] != project or pg['image'] != profile['images']['postgres']
                or pg.get('platform') != 'linux/amd64' or pg.get('privileged') or pg.get('cap_add')
                or pg.get('entrypoint') or pg.get('command') or len(pg['volumes']) != 1
                or pg['volumes'][0]['type'] != 'volume' or pg['volumes'][0]['source'] != 'postgres-data'
                or pg['volumes'][0]['target'] != '/var/lib/postgresql/data'):
            raise RuntimeError('Tracked PostgreSQL Compose identity/security profile changed.')
        resolved = {'user': pg['user'], 'readOnly': pg['read_only'], 'capDrop': pg['cap_drop'],
                    'securityOptions': pg['security_opt'], 'tmpfs': pg['tmpfs']}
        if resolved != profile['postgresExecution']:
            raise RuntimeError('Tracked PostgreSQL execution settings differ from the reviewed profile.')
        volume_name = definition['volumes']['postgres-data']['name']
        if (volume_name != project + '-postgres-data'
                or run(compose + ['ps', '--all', '--quiet'], env=environment).stdout.strip()
                or run(['docker', 'volume', 'inspect', volume_name], check=False).returncode == 0
                or run(['docker', 'network', 'ls', '--filter',
                        'label=com.docker.compose.project=' + project, '--quiet']).stdout.strip()):
            raise RuntimeError('Disposable context target already exists; it was left unchanged.')
        creation_attempted = True
        run(compose + ['up', '--detach', '--no-build', '--pull', 'never', '--wait',
                       '--wait-timeout', '90', 'postgres'], env=environment, timeout=120)
        identity = run(compose + ['ps', '--quiet', 'postgres'], env=environment).stdout.strip()
        if re.fullmatch(r'[a-f0-9]{64}', identity) is None:
            raise RuntimeError('Unexpected PostgreSQL context container identity.')
        container = inspect('container', identity)
        host = container['HostConfig']
        if (container['Config']['Labels'].get('com.docker.compose.project') != project
                or container['Image'] != context['imageConfigDigest'] or container['Config']['User'] != '70:70'
                or not host['ReadonlyRootfs'] or host.get('Privileged') or host.get('CapAdd')
                or host['CapDrop'] != ['ALL'] or host['SecurityOpt'] != ['no-new-privileges:true']):
            raise RuntimeError('Actual PostgreSQL container credentials or hardening changed.')
        mounts = [value for value in container['Mounts'] if value['Type'] != 'tmpfs']
        if (len(mounts) != 1 or mounts[0]['Type'] != 'volume' or mounts[0]['Name'] != volume_name
                or mounts[0]['Destination'] != '/var/lib/postgresql/data'):
            raise RuntimeError('Actual PostgreSQL container has unreviewed filesystem mounts.')
        context['execution'] = {'user': container['Config']['User'], 'readOnly': host['ReadonlyRootfs'],
            'capDrop': host['CapDrop'], 'securityOptions': host['SecurityOpt'],
            'tmpfs': [name + ':' + options for name, options in host['Tmpfs'].items()]}
        status = run(['docker', 'exec', identity, 'cat', '/proc/1/status']).stdout
        fields = dict(line.split(':', 1) for line in status.splitlines() if ':' in line)
        if any(re.fullmatch(r'0+', fields[name].strip()) is None for name in ('CapEff', 'CapPrm', 'CapAmb')):
            raise RuntimeError('The actual PostgreSQL process has capabilities.')
        context['process'] = {'uids': fields['Uid'].split(), 'gids': fields['Gid'].split(),
            'effectiveCapabilities': fields['CapEff'].strip(), 'noNewPrivileges': fields['NoNewPrivs'].strip() == '1'}
        context['helperInputFiles'] = []
        for path in ('/etc/passwd', '/etc/group', '/usr/local/bin/gosu'):
            stat = run(['docker', 'exec', identity, 'stat', '-c', '%u:%g:%a:%s', path]).stdout.strip().split(':')
            user, group, mode, size = stat
            if user != '0' or group != '0' or int(mode, 8) & 0o022 or int(size) > 2_000_000:
                raise RuntimeError('PostgreSQL helper inputs have unsafe ownership, permissions or size.')
            content = run(['docker', 'exec', identity, 'cat', path], binary=True).stdout
            if len(content) != int(size):
                raise RuntimeError('PostgreSQL helper input evidence is incomplete.')
            context['helperInputFiles'].append({'path': path, 'uid': user, 'gid': group, 'mode': mode,
                                               'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
        run(['docker', 'exec', identity, 'sh', '-euc',
             'test ! -w /etc/passwd && test ! -w /etc/group && test ! -w /usr/local/bin/gosu'])
        entrypoint = run(['docker', 'exec', identity, 'cat', '/usr/local/bin/docker-entrypoint.sh'], binary=True).stdout
        context['entrypointSha256'] = hashlib.sha256(entrypoint).hexdigest()
        context['bindMounts'] = sum(value['Type'] == 'bind' for value in container['Mounts'])
        context['onlyDataVolume'] = True
        networks = container['NetworkSettings']['Networks']
        context['networkInternal'] = len(networks) == 1 and all(inspect('network', name)['Internal'] for name in networks)
        context['publishedPorts'] = sum(bool(value) for value in (host.get('PortBindings') or {}).values())
        context['passed'] = True
    finally:
        try:
            if creation_attempted:
                ids = run(compose + ['ps', '--all', '--quiet'], env=environment).stdout.split()
                volumes = run(['docker', 'volume', 'ls', '--filter',
                               'label=com.docker.compose.project=' + project, '--format', '{{.Name}}']).stdout.split()
                networks = run(['docker', 'network', 'ls', '--filter',
                                'label=com.docker.compose.project=' + project, '--quiet']).stdout.split()
                for identity in ids:
                    if inspect('container', identity)['Config']['Labels'].get('com.docker.compose.project') != project:
                        raise RuntimeError('Refusing cleanup of a container not owned by this context probe.')
                for kind, names in (('volume', volumes), ('network', networks)):
                    for name in names:
                        if inspect(kind, name)['Labels'].get('com.docker.compose.project') != project:
                            raise RuntimeError('Refusing cleanup of an unowned context resource.')
                run(compose + ['down', '--volumes'], env=environment)
            for kind, flag, trailing in (('container', 'ownedContainersRemoved', '--quiet'),
                                         ('volume', 'ownedVolumesRemoved', '--quiet'),
                                         ('network', 'ownedNetworksRemoved', '--quiet')):
                command = ['docker', 'ps', '--all'] if kind == 'container' else ['docker', kind, 'ls']
                values = run(command + ['--filter', 'label=com.docker.compose.project=' + project, trailing]).stdout.strip()
                context['cleanup'][flag] = not bool(values)
        finally:
            shutil.rmtree(work)
            context['cleanup']['privateEnvironmentRemoved'] = not work.exists()
            context['capturedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            (OUTPUT / 'postgres-context.json').write_text(json.dumps(context, indent=2) + '\n')


def main():
    os.umask(0o077)
    OUTPUT.mkdir(exist_ok=True)
    source = run(['git', 'rev-parse', 'HEAD']).stdout.strip()
    if source != os.environ.get('EXPECTED_SOURCE_SHA'):
        raise RuntimeError('Infrastructure probe source differs from the expected immutable commit.')
    profile = json.loads((ROOT / '.gma/preview-infrastructure-profiles.json').read_text())['profiles']['maintained']
    references = dict(profile['images'], archiveUtility=profile['archiveUtilityImage'])
    codes = {}
    try:
        for name, image in references.items():
            run(['docker', 'pull', '--platform', 'linux/amd64', image])
            metadata = inspect('image', image)
            if (metadata['Id'] != profile['configurationIds'][name] or metadata['Os'] != 'linux'
                    or metadata['Architecture'] != 'amd64'):
                raise RuntimeError('Pulled infrastructure configuration changed: ' + name)
            result = run(['trivy', 'image', '--scanners', 'vuln,secret', '--severity', 'HIGH,CRITICAL',
                          '--list-all-pkgs', '--exit-code', '1', '--format', 'json', '--output',
                          str(OUTPUT / (name + '-security.json')), image], check=False, timeout=300)
            codes[name] = result.returncode
            if result.returncode not in (0, 1):
                raise RuntimeError('Infrastructure scanner failed before producing a complete report: ' + name)
    finally:
        (OUTPUT / 'infrastructure-scan-exit-codes.json').write_text(json.dumps(codes, indent=2) + '\n')
    collect_context(profile, source)


if __name__ == '__main__':
    main()
