#!/usr/bin/env python3
"""Assess exact Preview images; retain raw findings and require the PG consumer context."""

from collections import Counter
import concurrent.futures
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.request


ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False).encode()).hexdigest()


def records(text):
    decoder = json.JSONDecoder()
    while text.strip():
        value, end = decoder.raw_decode(text.lstrip())
        yield value
        text = text.lstrip()[end:]


def load_fixture(policy):
    path = ROOT / 'eng/operations/fixtures/preview-infrastructure-reviewed-evidence.json.gz'
    encoded = path.read_bytes()
    require(len(encoded) <= 512_000 and hashlib.sha256(encoded).hexdigest() == policy['fixtureSha256'],
            'Reviewed infrastructure evidence changed or exceeded its bound.')
    with gzip.open(path, 'rb') as stream:
        content = stream.read(4_000_001)
    require(len(content) <= 4_000_000, 'Reviewed infrastructure evidence exceeds its decompressed bound.')
    return json.loads(content)


def fetch_advisories(policy):
    def fetch(identity):
        require(re.fullmatch(r'GO-\d{4}-\d+', identity), 'Unexpected advisory identity.')
        with urllib.request.urlopen('https://vuln.go.dev/ID/' + identity + '.json', timeout=30) as response:
            content = response.read(2_000_001)
        require(len(content) <= 2_000_000, 'Primary advisory exceeds its bound.')
        return identity, json.loads(content)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        return dict(executor.map(fetch, policy['postgres']['advisorySha256']))


def verify_helper(policy, fixture, advisories):
    pg = policy['postgres']
    raw = fixture['helperRawReport']
    summary = fixture['helperSummary']
    require(hashlib.sha256(raw.encode()).hexdigest() == pg['helperRawReportSha256'] == summary['rawReportSha256']
            and summary['helperSha256'] == pg['helperSha256']
            and summary['imageConfigDigest'] == pg['imageConfigDigest']
            and summary['analyzerSha256'] == pg['analyzerSha256'],
            'The qualified image/helper/analyzer/raw-report binding changed.')
    messages = list(records(raw))
    configs = [value['config'] for value in messages if 'config' in value]
    require(len(configs) == 1 and configs[0]['scanner_name'] == 'govulncheck'
            and configs[0]['scanner_version'] == 'v1.9.0' and configs[0]['scan_level'] == 'symbol'
            and configs[0]['scan_mode'] == 'binary' and configs[0]['db'] == 'https://vuln.go.dev'
            and configs[0] == summary['analyzerConfiguration'], 'Unmodified binary symbol analysis is required.')
    original = {value['osv']['id']: value['osv'] for value in messages if 'osv' in value}
    expected = set(pg['advisorySha256'])
    require(set(advisories) == expected, 'Primary advisory coverage is missing or duplicated.')
    for identity in expected:
        require(identity in original and advisories[identity]['id'] == identity
                and canonical_hash(advisories[identity]) == pg['advisorySha256'][identity]
                == canonical_hash(original[identity]),
                'A primary advisory changed; rerun and review the helper analysis: ' + identity)
    for cve, identities in pg['stdlibCves'].items():
        require(identities and all(cve in original[identity].get('aliases', []) for identity in identities),
                'A reported CVE is not covered by the qualified analysis.')
        for identity in identities:
            imports = [item for affected in original[identity]['affected']
                       for item in affected.get('ecosystem_specific', {}).get('imports', [])]
            require(imports and all(item.get('symbols') for item in imports),
                    'Missing affected-function metadata cannot prove symbol absence.')
    findings = [value['finding'] for value in messages if 'finding' in value]
    symbols = [(finding['osv'], finding['trace'][0]['function']) for finding in findings
               if finding.get('trace') and finding['trace'][0].get('function')]
    require(Counter(symbols) == Counter((pg['contextOsv'], name) for name in
            ('GetExecUserPath', 'ParseGroupFilter', 'GetExecUser')),
            'Additional vulnerable symbols remain outside the bounded user/group-file context review.')


def verify_context(policy, profile, context, source):
    pg = policy['postgres']
    require(context['schemaVersion'] == 1 and context['sourceCommit'] == source
            and re.fullmatch(r'[a-f0-9]{40}', source) and context['passed'] is True,
            'Current-source actual PostgreSQL context evidence is missing.')
    require(context['image'] == pg['image'] and context['imageConfigDigest'] == pg['imageConfigDigest'],
            'The context belongs to a different PostgreSQL image.')
    def execution(value):
        require(set(value) == {'user', 'readOnly', 'capDrop', 'securityOptions', 'tmpfs'},
                'PostgreSQL execution metadata must have the exact reviewed fields.')
        require(value['readOnly'] is True, 'PostgreSQL read-only metadata must be boolean true.')
        result = dict(value)
        result['tmpfs'] = sorted(path + ':' + ','.join(sorted(options.split(',')))
                                 for path, options in (item.split(':', 1) for item in value['tmpfs']))
        return result
    require(execution(context['execution']) == execution(profile['postgresExecution']),
            'Actual PostgreSQL execution differs from the reviewed UID70/read-only profile.')
    process = context['process']
    require(process['uids'] == ['70'] * 4 and process['gids'] == ['70'] * 4
            and re.fullmatch(r'0+', process['effectiveCapabilities'])
            and process['noNewPrivileges'] is True, 'The actual database process is not unprivileged.')
    require(context['bindMounts'] == 0 and context['onlyDataVolume'] is True
            and context['networkInternal'] is True and context['publishedPorts'] == 0,
            'The database context permits unreviewed mounts or network exposure.')
    require(context['entrypointSha256'] == pg['entrypointSha256']
            and context['helperInputFiles'] == pg['helperInputFiles'],
            'The root-only gosu branch or bounded root-owned helper input files changed.')
    require(set(context['cleanup']) == {'ownedContainersRemoved', 'ownedVolumesRemoved',
            'ownedNetworksRemoved', 'privateEnvironmentRemoved'}
            and all(value is True for value in context['cleanup'].values()),
            'Owned context resources or generated secrets were not cleaned up.')


def verify(policy, profiles, scans, context, tool, fixture, advisories, codes, source, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    issued = datetime.datetime.fromisoformat(policy['reviewedAt'])
    expiry = datetime.datetime.fromisoformat(policy['reviewExpiresAt'])
    require(policy['schemaVersion'] == 1 and issued <= now < expiry
            and expiry - issued <= datetime.timedelta(days=30), 'Infrastructure assessment is expired or invalid.')
    require(tool['name'] == 'Trivy' and tool['version'] == '0.76.1'
            and tool['archiveSha256'] == 'c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0',
            'An unverified scanner result cannot qualify infrastructure.')
    profile = profiles['profiles']['maintained']
    verify_helper(policy, fixture, advisories)
    verify_context(policy, profile, context, source)
    require(set(scans) == set(codes) == set(policy['coverage']) ==
            {'postgres', 'redis', 'nats', 'mailpit', 'archiveUtility'}, 'Exact infrastructure scan set required.')
    findings = []
    for name, scan in scans.items():
        image = profile['archiveUtilityImage'] if name == 'archiveUtility' else profile['images'][name]
        require(scan['SchemaVersion'] == 2 and scan['ArtifactType'] == 'container_image'
                and scan['ArtifactName'] == image, 'Raw image scanner subject changed: ' + name)
        created = datetime.datetime.fromisoformat(scan['CreatedAt'].replace('Z', '+00:00'))
        require(datetime.timedelta(0) <= now - created <= datetime.timedelta(hours=2), 'Fresh raw scan required: ' + name)
        metadata = scan['Metadata']
        repository = image.split('@')[0].rsplit(':', 1)[0]
        require(metadata['ImageID'] == profile['configurationIds'][name]
                and metadata['ImageConfig']['os'] == 'linux'
                and metadata['ImageConfig']['architecture'] == 'amd64'
                and metadata['RepoDigests'] == [repository + '@' + image.rsplit('@', 1)[1]],
                'Raw scan configuration/platform/registry digest changed: ' + name)
        results = scan['Results']
        targets = {value['Target']: value for value in results}
        require(len(targets) == len(results) and set(targets) == set(policy['coverage'][name]),
                'Scanner targets disappeared or duplicated: ' + name)
        seen = set()
        count = 0
        for target, result in targets.items():
            require(len(result.get('Packages', [])) >= policy['coverage'][name][target],
                    'Scanner package inventory is missing or reduced: ' + name)
            require(not any(result.get(key) for key in ('Secrets', 'Misconfigurations', 'CustomResources')),
                    'Unreviewed secret or configuration findings remain: ' + name)
            for finding in result.get('Vulnerabilities', []):
                identity = finding['VulnerabilityID']
                require(name == 'postgres' and target == 'usr/local/bin/gosu' and identity not in seen,
                        'Unreviewed or duplicated infrastructure vulnerability: ' + identity)
                seen.add(identity)
                stdlib = (identity in policy['postgres']['stdlibCves'] and finding['PkgName'] == 'stdlib'
                          and finding['InstalledVersion'] == 'v1.24.6'
                          and finding['PkgIdentifier']['PURL'] == 'pkg:golang/stdlib@v1.24.6')
                bounded = (identity == policy['postgres']['contextCve']
                           and finding['PkgName'] == 'github.com/moby/sys/user'
                           and finding['InstalledVersion'] == 'v0.1.0'
                           and finding['PkgIdentifier']['PURL'] == 'pkg:golang/github.com/moby/sys/user@v0.1.0')
                require(stdlib or bounded, 'Infrastructure vulnerability lacks exact symbol/context evidence: ' + identity)
                count += 1
                findings.append({'cve': identity, 'target': target, 'package': finding['PkgIdentifier']['PURL'],
                                 'basis': 'affected helper function absent' if stdlib else 'bounded immutable helper inputs in enforced PG context'})
        require(type(codes[name]) is int and codes[name] == (1 if count else 0),
                'Scanner exit code is missing or inconsistent: ' + name)
    return {'schemaVersion': 1, 'sourceCommit': source, 'result': 'passed',
            'rawHighCriticalFindings': len(findings), 'conditionalConsumerAssessments': findings,
            'unresolvedSecurityFindings': 0, 'reviewExpiresAt': policy['reviewExpiresAt'],
            'advisoriesRevalidated': len(advisories), 'postgresContextCve': policy['postgres']['contextCve'],
            'scope': 'Exact Linux amd64 engineering Preview only. Raw findings retained. Requires the enforced image and PG execution profile; not universal image clearance or production admission.'}


def main():
    destination = ROOT / 'artifacts'
    load = lambda path: json.loads(path.read_text())
    policy = load(ROOT / '.gma/preview-infrastructure-review.json')
    fixture = load_fixture(policy)
    advisories = fetch_advisories(policy)
    (destination / 'postgres-current-advisories.json').write_text(json.dumps(advisories, indent=2) + '\n')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    scans = {name: load(destination / (name + '-security.json')) for name in policy['coverage']}
    summary = verify(policy, load(ROOT / '.gma/preview-infrastructure-profiles.json'), scans,
                     load(destination / 'postgres-context.json'), load(destination / 'tool-identity.json'),
                     fixture, advisories, load(destination / 'infrastructure-scan-exit-codes.json'), source)
    (destination / 'infrastructure-security-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({key: summary[key] for key in ('result', 'rawHighCriticalFindings',
          'unresolvedSecurityFindings', 'advisoriesRevalidated', 'reviewExpiresAt')}))


if __name__ == '__main__':
    main()
