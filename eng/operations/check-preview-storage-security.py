#!/usr/bin/env python3
"""Apply the owning backend's registry-storage gate to the root's own policy."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / 'apps/backend'
HELPERS = ('eng/operations/check-preview-storage-security.py',
           'eng/operations/inspect-preview-storage-parser.py',
           'eng/operations/image-config-digest.py')
_backend = None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def require_pinned_backend():
    def git(root, *arguments):
        result = subprocess.run(['git', '-C', str(root), *arguments], capture_output=True, timeout=60)
        require(result.returncode == 0, 'Cannot verify the pinned backend storage-gate source.')
        return result.stdout
    pin = git(ROOT, 'rev-parse', 'HEAD:apps/backend').decode().strip()
    actual = git(BACKEND, 'rev-parse', 'HEAD').decode().strip()
    require(actual == pin, 'Storage assessment must use exactly the root backend gitlink.')
    for relative in HELPERS:
        require((BACKEND / relative).read_bytes() == git(BACKEND, 'show', 'HEAD:' + relative),
                'A pinned backend storage helper has local modifications: ' + relative)


def load_backend():
    global _backend
    if _backend is None:
        spec = importlib.util.spec_from_file_location('bunkfy_owned_storage_gate', BACKEND / HELPERS[0])
        owner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(owner)
        _backend = owner
    return _backend


def verify(policy, scan, runtime, sbom, tool, scan_exit_code, now=None, binary_evidence=None):
    # Root policy, original registry subject and original runtime observations
    # stay explicit. A backend fixture/derivation is never substituted here.
    return load_backend().verify(policy, scan, runtime, sbom, tool, scan_exit_code,
                                 now=now, binary_evidence=binary_evidence)


def source_checks(policy):
    return load_backend().source_checks(policy)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('artifacts'))
    parser.add_argument('--scanner-exit-code', type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    require_pinned_backend()
    policy = json.loads((ROOT / '.gma/preview-storage-review.json').read_text())
    load = lambda name: json.loads((args.directory / name).read_text())
    scan = load('silo-security.json')
    owner = load_backend()
    binary_evidence = None
    if any(finding.get('VulnerabilityID') == owner.parser_audit.CVE
           for result in scan.get('Results', []) for finding in result.get('Vulnerabilities', [])):
        binary_evidence = owner.parser_audit.collect(policy['imageConfigDigest'], image_reference=policy['image'])
        (args.directory / 'silo-parser-applicability.json').write_text(json.dumps(binary_evidence, indent=2) + '\n')
    summary, vex = verify(policy, scan, load('silo-runtime.json'), load('silo-sbom.cdx.json'),
                          load('tool-identity.json'), args.scanner_exit_code, binary_evidence=binary_evidence)
    summary['reviewedSourceChecks'] = source_checks(policy)
    (args.directory / 'silo-security-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (args.directory / 'silo-fixed-fork.vex.json').write_text(json.dumps(vex, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
