#!/usr/bin/env python3
"""Scan pinned public infrastructure images without a Docker daemon or app build."""

import datetime
import json
import os
from pathlib import Path
import re
import subprocess


IMAGES = {
    'postgres': 'postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa',
    'redis': 'redis:8.0-alpine@sha256:5f61955be8ab2ccee9372b84ae4d4da2e2b156f87281e3f218544055e7ee04d4',
    'nats': 'nats:2.11-alpine@sha256:e4bf19f15fd3218814a4e3c9e0064e1334bd8aa20d5984b9f1a0afd084f8cc00',
    'mailpit': 'axllent/mailpit:v1.30.7@sha256:d5ecbb067db3705fa953d79e1b7f81ef84038df67aba6c52825d8c02a1ea748a',
}


def main():
    expected = os.environ.get('EXPECTED_SOURCE_SHA', '')
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if re.fullmatch(r'[a-f0-9]{40}', expected) is None or actual != expected:
        raise RuntimeError('Manual inventory source does not match the expected immutable commit.')
    destination = Path('artifacts/infrastructure')
    destination.mkdir(parents=True, exist_ok=True)
    tool = json.loads(Path('artifacts/tool-identity.json').read_text())
    if tool['version'] != '0.76.1' or tool['archiveSha256'] != 'c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0':
        raise RuntimeError('Scanner must match the reviewed official release bytes.')
    (destination / 'tool-identity.json').write_text(json.dumps(tool, indent=2) + '\n')
    records = []
    for service, image in IMAGES.items():
        record = {'service': service, 'image': image, 'result': 'failed'}
        path = destination / (service + '-raw-vulnerabilities.json')
        try:
            result = subprocess.run(
                ['trivy', 'image', '--image-src', 'remote', '--platform', 'linux/amd64',
                 '--scanners', 'vuln', '--severity', 'HIGH,CRITICAL', '--list-all-pkgs',
                 '--exit-code', '1', '--format', 'json', '--output', str(path), image],
                capture_output=True, text=True, timeout=300)
            if result.returncode not in (0, 1) or not path.is_file():
                raise RuntimeError('Image scan failed before a complete raw report was available.')
            raw = json.loads(path.read_text())
            if raw['SchemaVersion'] != 2 or raw['ArtifactType'] != 'container_image' or raw['ArtifactName'] != image:
                raise RuntimeError('Raw report subject does not match the requested immutable image.')
            metadata = raw['Metadata']
            if (re.fullmatch(r'sha256:[a-f0-9]{64}', metadata['ImageID']) is None or
                    metadata['ImageConfig']['os'] != 'linux' or metadata['ImageConfig']['architecture'] != 'amd64'):
                raise RuntimeError('Scanned platform or configuration identity is missing.')
            targets = raw.get('Results', [])
            packages = sum(len(target.get('Packages', [])) for target in targets)
            if packages < 1:
                raise RuntimeError('The image package inventory is missing.')
            findings = [finding for target in targets for finding in target.get('Vulnerabilities', [])]
            if result.returncode != (1 if findings else 0):
                raise RuntimeError('Scanner exit status is inconsistent with its raw findings.')
            record.update(result='requires-review' if findings else 'no-high-or-critical-findings',
                          imageConfigDigest=metadata['ImageID'], repoDigests=metadata.get('RepoDigests', []),
                          packages=packages, high=sum(x['Severity'] == 'HIGH' for x in findings),
                          critical=sum(x['Severity'] == 'CRITICAL' for x in findings),
                          findings=[{'id': x['VulnerabilityID'], 'package': x['PkgName'],
                                     'version': x['InstalledVersion'], 'fixedVersion': x.get('FixedVersion'),
                                     'severity': x['Severity'], 'primaryUrl': x.get('PrimaryURL')}
                                    for x in findings], rawReport=path.name)
        except Exception as error:
            # No deployment credentials or response headers are supplied or retained.
            record['error'] = str(error).splitlines()[0][:300]
        records.append(record)
        print(json.dumps({key: record.get(key) for key in ('service', 'result', 'high', 'critical', 'packages')}), flush=True)
    summary = {'schemaVersion': 1, 'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'sourceCommit': actual, 'composeSourceCommit': '8811912b13b9cffb7cccb68dfcd2ac9132895564',
               'platform': 'linux/amd64', 'images': records,
               'scope': 'Current pinned public-image vulnerability inventory only. No containers, application builds, '
                        'production data or credentials. Secrets/behavior/recovery/production admission are outside this scan.',
               'result': 'passed' if all(x['result'] == 'no-high-or-critical-findings' for x in records) else 'requires-review'}
    (destination / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    if summary['result'] != 'passed':
        raise SystemExit('Pinned infrastructure has unresolved findings or scan failures; retained raw reports need review.')


if __name__ == '__main__':
    main()
