#!/usr/bin/env python3
"""Qualify the pinned Preview fixture and retain a scoped fixed-fork assessment."""

import argparse
from collections import Counter
import datetime
import hashlib
import json
from pathlib import Path
import urllib.request


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(policy, scan, runtime, sbom, tool, scan_exit_code, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    issued = datetime.datetime.fromisoformat(policy['reviewedAt'])
    expiry = datetime.datetime.fromisoformat(policy['reviewExpiresAt'])
    require(issued <= now < expiry and expiry - issued <= datetime.timedelta(days=30),
            'Storage assessment is expired, future-dated or exceeds thirty days.')
    require(policy['schemaVersion'] == 1 and policy['status'] == 'fixed'
            and policy['vulnerability'] == 'CVE-2026-39414', 'Only the reviewed fixed-fork assessment is supported.')
    require(policy['platform'] == 'linux/amd64', 'Only the qualified Linux amd64 fixture is supported.')
    require(scan['SchemaVersion'] == 2 and scan['ArtifactType'] == 'container_image'
            and scan['ArtifactName'] == policy['image'], 'Raw scanner subject does not match the reviewed immutable image.')
    created = datetime.datetime.fromisoformat(scan['CreatedAt'].replace('Z', '+00:00'))
    require(datetime.timedelta(0) <= now - created <= datetime.timedelta(hours=2), 'A fresh raw image scan is required.')
    metadata = scan['Metadata']
    require(metadata['ImageID'] == policy['imageConfigDigest'], 'Image configuration digest changed.')
    config = metadata['ImageConfig']
    require(config['architecture'] == 'amd64' and config['os'] == 'linux'
            and config['config']['Labels']['org.opencontainers.image.revision'] == policy['sourceCommit'],
            'Image platform or reviewed source revision changed.')
    image_digest = policy['image'].rsplit('@', 1)[1]
    require(metadata['RepoDigests'] == ['pgsty/silo@' + image_digest], 'Registry image subject changed.')
    require(tool['name'] == 'Trivy' and tool['version'] == '0.76.1'
            and tool['archiveSha256'] == 'c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0',
            'Use the reviewed scanner binary, not an unverified tool result.')
    root_component = sbom['metadata']['component']
    require(root_component['name'] == policy['image'] and root_component['type'] == 'container', 'SBOM subject changed.')
    image_property = [value['value'] for value in root_component['properties']
                      if value['name'] == 'aquasecurity:trivy:ImageID']
    require(image_property == [policy['imageConfigDigest']], 'SBOM image configuration digest changed.')
    expected_purl = ('pkg:oci/silo@' + image_digest
                     + '?arch=amd64&repository_url=index.docker.io%2Fpgsty%2Fsilo')
    require(root_component['purl'] == expected_purl, 'VEX must identify only this image digest and platform.')
    targets = {value['Target']: value for value in scan['Results']}
    expected_targets = {policy['image'] + ' (redhat 9.8)': 22, 'usr/bin/mcli': 108, 'usr/bin/silo': 264}
    require(set(targets) == set(expected_targets) and len(scan['Results']) == len(targets), 'Scanner targets disappeared or duplicated.')
    for name, minimum in expected_targets.items():
        require(len(targets[name].get('Packages', [])) >= minimum, 'Scanner package inventory is missing or reduced: ' + name)
    findings = []
    for result in scan['Results']:
        require(not any(result.get(key) for key in ('Secrets', 'Misconfigurations', 'CustomResources')),
                'Unreviewed secret or configuration findings remain.')
        for finding in result.get('Vulnerabilities', []):
            match = (result['Target'] == policy['binaryTarget']
                     and finding['VulnerabilityID'] == policy['vulnerability']
                     and finding.get('PkgIdentifier', {}).get('PURL') == policy['packagePurl']
                     and finding['PkgName'] == 'github.com/minio/minio'
                     and finding['InstalledVersion'] == policy['packagePurl'].rsplit('@', 1)[1]
                     and finding['Severity'] == 'HIGH')
            require(match, 'A vulnerability outside the exact reviewed image/module/fix remains unresolved.')
            findings.append(finding)
    require(len(findings) <= 1, 'The reviewed finding duplicated across the scanner report.')
    require(scan_exit_code == (1 if findings else 0), 'Scanner exit status is missing or inconsistent with its raw report.')
    require(runtime['image'] == policy['image']
            and runtime['expectedSourceRevision'] == policy['sourceCommit']
            and runtime['actualSourceRevision'] == policy['sourceCommit']
            and runtime['result'] == 'passed', 'Actual runtime evidence does not qualify the reviewed image.')
    flags = {'containerRemoved', 'volumeRemoved', 'networkRemoved', 'generatedEnvironmentRemoved'}
    require(set(runtime['cleanup']) == flags
            and all(type(value) is bool and value for value in runtime['cleanup'].values()),
            'Storage cleanup is incomplete or unverified.')
    ordinary = {
        'readiness': 200, 'liveness': 200, 'anonymous account listing denied': 403,
        'create private bucket': 200, 'signed private object put': 200,
        'signed exact object read': 200, 'anonymous object read denied': 403,
        'invalid signature denied': 403, 'signed object head': 200, 'bounded range read': 206,
        'wrong entity tag rejected': 412, 'matching entity tag read': 200,
        'bounded prefix listing': 200, 'object survives provider restart': 200,
        'signed object deletion': 204, 'deleted object unavailable': 404, 'empty bucket deletion': 204,
    }
    expected_cases = Counter({name: 1 for name in ordinary})
    for label in ('CSV', 'JSON Lines', 'gzip CSV'):
        ordinary[label + ' probe object write'] = 200
        ordinary[label + ' service remains ready'] = 200
        ordinary[label + ' probe object deletion'] = 204
        expected_cases.update({label + ' probe object write': 2, label + ' service remains ready': 2,
                               label + ' probe object deletion': 1, label + ' positive Select control': 1,
                               label + ' oversized record rejected': 1})
    require(Counter(case['case'] for case in runtime['observations']) == expected_cases,
            'Storage or CVE binary controls are missing, duplicated or changed.')
    for case in runtime['observations']:
        name = case['case']
        if name in ordinary:
            require(case['actualStatus'] == case['expectedStatus'] == ordinary[name], 'A required S3 contract failed.')
        elif name.endswith('positive Select control'):
            require(case['httpStatus'] == 200 and case['errorCode'] is None, 'A positive Select control failed.')
        else:
            require(case['httpStatus'] in (200, 400) and case['errorCode'] == 'OverMaxRecordSize',
                    'A reviewed record-limit regression failed.')
    summary = {'schemaVersion': 1, 'result': 'passed', 'image': policy['image'],
               'imageConfigDigest': policy['imageConfigDigest'], 'platform': policy['platform'],
               'sourceCommit': policy['sourceCommit'], 'rawHighFindings': len(findings),
               'fixedInReviewedFork': len(findings), 'unresolvedSecurityFindings': 0,
               'runtimeObservations': len(runtime['observations']), 'reviewExpiresAt': policy['reviewExpiresAt'],
               'qualification': 'Exact engineering fixture only. Raw finding retained; no global ignore or production approval.'}
    vex = {'@context': 'https://openvex.dev/ns/v0.2.0',
           '@id': 'https://github.com/SadPossum/BunkFy/engineering-assessments/' + policy['sourceCommit'] + '/CVE-2026-39414',
           'author': 'Codex engineering continuation review for BunkFy',
           'role': 'Consumer assessment; not supplier-issued or a production approval',
           'timestamp': policy['reviewedAt'], 'version': 1,
           'statements': [{'vulnerability': {'name': policy['vulnerability']}, 'status': 'fixed',
                           'products': [{'@id': root_component['purl'],
                                         'hashes': {'sha-256': image_digest.removeprefix('sha256:')},
                                         'subcomponents': [{'@id': policy['packagePurl']}]}],
                           'status_notes': policy['assessment'] + ' Primary advisory: ' + policy['primaryAdvisory']
                                           + ' Supplier disclosure: ' + policy['supplierDisclosure']}]}
    return summary, vex


def source_checks(policy):
    results = []
    require(set(policy['sourceFilesSha256']) == {
        'internal/s3select/csv/reader.go', 'internal/s3select/json/preader.go', 'internal/s3select/select.go'
    }, 'CSV, JSON Lines and CPU-independent dispatch source evidence are all required.')
    for path, expected in policy['sourceFilesSha256'].items():
        url = 'https://raw.githubusercontent.com/pgsty/silo/' + policy['sourceCommit'] + '/' + path
        with urllib.request.urlopen(url, timeout=30) as response:
            contents = response.read(256 * 1024)
        require(hashlib.sha256(contents).hexdigest() == expected, 'Reviewed immutable source bytes changed: ' + path)
        results.append({'path': path, 'sha256': expected})
    require(len(results) == 3, 'The CSV, JSON Lines and dispatch source evidence must all be checked.')
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('artifacts'))
    parser.add_argument('--scanner-exit-code', type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    policy = json.loads((root / '.gma/preview-storage-review.json').read_text())
    load = lambda name: json.loads((args.directory / name).read_text())
    summary, vex = verify(policy, load('silo-security.json'), load('silo-runtime.json'),
                          load('silo-sbom.cdx.json'), load('tool-identity.json'), args.scanner_exit_code)
    summary['reviewedSourceChecks'] = source_checks(policy)
    (args.directory / 'silo-security-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (args.directory / 'silo-fixed-fork.vex.json').write_text(json.dumps(vex, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
