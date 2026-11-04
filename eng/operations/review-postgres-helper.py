#!/usr/bin/env python3
"""Collect exact PostgreSQL helper symbol evidence; never suppress raw findings."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.request


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(arguments, *, environment=None, timeout=180):
    result = subprocess.run(arguments, env=environment, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Analysis prerequisite failed: ' + arguments[0] + '\n' + result.stderr[-2000:])
    return result.stdout


def messages(text):
    decoder = json.JSONDecoder()
    while text.strip():
        value, end = decoder.raw_decode(text.lstrip())
        yield value
        text = text.lstrip()[end:]


def main():
    actual = run(['git', 'rev-parse', 'HEAD']).strip()
    expected = os.environ.get('EXPECTED_SOURCE_SHA', '')
    if re.fullmatch(r'[a-f0-9]{40}', expected) is None or actual != expected:
        raise RuntimeError('Analysis source must match the immutable reviewed commit.')
    review = json.loads(Path('.gma/postgres-helper-review.json').read_text())
    destination = Path('artifacts/postgres-helper').resolve()
    destination.mkdir(parents=True, exist_ok=True)
    work = Path(os.environ['RUNNER_TEMP']) / ('bunkfy-helper-' + actual[:12])
    work.mkdir(exist_ok=False)

    archive = work / 'go.tar.gz'
    with urllib.request.urlopen(review['go']['url'], timeout=60) as response, archive.open('wb') as target:
        while block := response.read(1024 * 1024):
            target.write(block)
            if target.tell() > 100_000_000:
                raise RuntimeError('Unexpected Go toolchain archive size.')
    if digest(archive) != review['go']['sha256']:
        raise RuntimeError('Official Go toolchain checksum does not match.')
    with tarfile.open(archive, 'r:gz') as package:
        members = package.getmembers()
        if len(members) > 30_000 or sum(item.size for item in members) > 700_000_000:
            raise RuntimeError('Unexpected Go toolchain extraction size.')
        package.extractall(work, filter='data')
    archive.unlink()
    environment = dict(os.environ, GOTOOLCHAIN='local', GOPROXY='https://proxy.golang.org',
                       GOSUMDB='sum.golang.org', GOBIN=str(work / 'bin'), GOPATH=str(work / 'gopath'),
                       GOCACHE=str(work / 'cache'), GOMAXPROCS='2', GOTELEMETRY='off')
    environment['PATH'] = str(work / 'go/bin') + os.pathsep + environment['PATH']
    go = str(work / 'go/bin/go')
    version = run([go, 'version'], environment=environment)
    if 'go1.27.3 linux/amd64' not in version:
        raise RuntimeError('Unexpected analysis toolchain.')
    run([go, 'install', 'golang.org/x/vuln/cmd/govulncheck@v1.9.0'],
        environment=environment, timeout=360)
    tool = work / 'bin/govulncheck'
    build_info = run([go, 'version', '-m', str(tool)], environment=environment)
    if re.search(r'\bmod\s+golang.org/x/vuln\s+v1\.9\.0\s+h1:', build_info) is None:
        raise RuntimeError('Installed analyzer module identity is missing.')
    (destination / 'analyzer-build-info.txt').write_text(build_info)

    image = review['image']
    run(['docker', 'pull', '--platform', 'linux/amd64', image], timeout=180)
    configuration = json.loads(run(['docker', 'image', 'inspect', image]))
    if (len(configuration) != 1 or configuration[0]['Id'] != review['imageConfigDigest'] or
            configuration[0]['Os'] != 'linux' or configuration[0]['Architecture'] != 'amd64'):
        raise RuntimeError('Actual PostgreSQL image subject does not match the reviewed subject.')
    container = None
    helper = work / 'gosu'
    try:
        # Create an inert filesystem container; do not start it or a database.
        container = run(['docker', 'create', '--network', 'none', '--user', '70:70',
                         '--entrypoint', '/bin/false', image]).strip()
        if re.fullmatch(r'[a-f0-9]{64}', container) is None:
            raise RuntimeError('Unexpected inert container identity.')
        run(['docker', 'cp', container + ':/usr/local/bin/gosu', str(helper)])
    finally:
        if container:
            run(['docker', 'rm', container])
    os.chmod(helper, 0o600)
    if digest(helper) != review['helperSha256']:
        raise RuntimeError('Image helper does not match the exact published gosu 1.19 asset.')
    helper_build = run([go, 'version', '-m', str(helper)], environment=environment)
    (destination / 'helper-build-info.txt').write_text(helper_build)
    raw_path = destination / 'govulncheck-binary.json'
    with raw_path.open('w') as output:
        result = subprocess.run([str(tool), '-mode=binary', '-format=json', str(helper)],
                                env=environment, stdout=output, stderr=subprocess.PIPE,
                                text=True, timeout=240)
    (destination / 'govulncheck-stderr.txt').write_text(result.stderr)
    if result.returncode not in (0, 3):
        raise RuntimeError('Binary analysis did not complete: ' + result.stderr[-1500:])
    if raw_path.stat().st_size > 15_000_000:
        raise RuntimeError('Unexpected analyzer report size.')
    records = list(messages(raw_path.read_text()))
    configurations = [record['config'] for record in records if 'config' in record]
    if len(configurations) != 1:
        raise RuntimeError('Analyzer report configuration is missing or duplicated.')
    advisories = {record['osv']['id']: record['osv'] for record in records if 'osv' in record}
    findings = [record['finding'] for record in records if 'finding' in record]
    symbol_findings = [finding for finding in findings
                       if finding.get('trace') and finding['trace'][0].get('function')]
    aliases = {alias for advisory in advisories.values() for alias in advisory.get('aliases', [])}
    missing = sorted(set(review['baselineCves']) - aliases)
    relevant = [{'id': finding['osv'],
                 'aliases': advisories.get(finding['osv'], {}).get('aliases', []),
                 'trace': finding.get('trace', [])} for finding in symbol_findings]
    summary = {
        'schemaVersion': 1,
        'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'sourceCommit': actual,
        'image': image,
        'imageConfigDigest': configuration[0]['Id'],
        'helperSha256': digest(helper),
        'helperRelease': review['helperRelease'],
        'baselineArtifact': review['baselineArtifact'],
        'analyzerVersion': 'v1.9.0',
        'analyzerSha256': digest(tool),
        'analyzerToolchain': version.strip(),
        'analyzerConfiguration': configurations[0],
        'analyzerExitCode': result.returncode,
        'rawReportSha256': digest(raw_path),
        'advisoryCount': len(advisories),
        'findingCount': len(findings),
        'symbolFindings': relevant,
        'baselineCves': review['baselineCves'],
        'baselineCvesMissingFromAnalyzerReport': missing,
        'inertFilesystemContainerRemoved': True,
        'databaseStarted': False,
        'scope': 'Conservative binary symbol evidence only. Presence does not prove reachability; '
                 'missing advisory coverage does not prove absence. No vendor exclusions, '
                 'global ignores, deployment, image publication, or security approval.',
        'result': 'requires-review' if relevant or missing else 'no-symbol-findings-with-complete-baseline-coverage'
    }
    (destination / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({key: summary[key] for key in ('imageConfigDigest', 'advisoryCount',
          'findingCount', 'baselineCvesMissingFromAnalyzerReport', 'result')}))
    if relevant or missing:
        raise SystemExit('Helper symbol findings or advisory coverage require review; raw evidence retained.')


if __name__ == '__main__':
    main()
