#!/usr/bin/env python3
"""Apply the owning backend's registry-storage gate to the root's own policy."""
import argparse
import copy
import hashlib
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


def verify(policy, scan, runtime, sbom, tool, scan_exit_code, now=None, binary_evidence=None, image_descriptors=None):
    owner = load_backend()
    original_id = scan['Metadata']['ImageID']
    configuration = policy['imageConfigDigest']
    if original_id == configuration:
        return owner.verify(policy, scan, runtime, sbom, tool, scan_exit_code,
                            now=now, binary_evidence=binary_evidence)
    # Verify the original content-addressed index/manifest -> configuration chain.
    # The owning registry gate expects the classic Docker configuration-ID view.
    # Adapt only those identity aliases in copies; retain both raw producer files.
    owner.bind_scanner_configuration(scan['Metadata'], configuration,
                                     {'imageDescriptors': image_descriptors or {}})
    properties = sbom['metadata']['component']['properties']
    ids = [p for p in properties if p['name'] == 'aquasecurity:trivy:ImageID']
    require(len(ids) == 1 and ids[0]['value'] == original_id,
            'Original SBOM identity differs from the cryptographically bound raw scanner subject.')
    adapted_scan, adapted_sbom = copy.deepcopy(scan), copy.deepcopy(sbom)
    adapted_scan['Metadata']['ImageID'] = configuration
    for prop in adapted_sbom['metadata']['component']['properties']:
        if prop['name'] == 'aquasecurity:trivy:ImageID':
            prop['value'] = configuration
    summary, vex = owner.verify(policy, adapted_scan, runtime, adapted_sbom, tool, scan_exit_code,
                                now=now, binary_evidence=binary_evidence)
    summary['scannerIdentityBinding'] = {'rawImageId': original_id, 'imageConfigDigest': configuration,
        'basis': 'Hashed original OCI descriptors; registry subject and all findings remain unchanged.',
        'rawReportsRetained': True}
    return summary, vex


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
    descriptors = None
    if scan['Metadata']['ImageID'] != policy['imageConfigDigest']:
        spec = importlib.util.spec_from_file_location('silo_image_identity', BACKEND / HELPERS[2])
        identity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(identity)
        proof_path = args.directory / 'silo-image-descriptors.json'
        require(identity.image_config_digest(policy['image'], proof_path) == policy['imageConfigDigest'],
                'Actual registry storage configuration differs from its reviewed pin.')
        descriptors = json.loads(proof_path.read_text())
    summary, vex = verify(policy, scan, load('silo-runtime.json'), load('silo-sbom.cdx.json'),
                          load('tool-identity.json'), args.scanner_exit_code, binary_evidence=binary_evidence, image_descriptors=descriptors)
    summary['rawScannerReportSha256'] = hashlib.sha256((args.directory / 'silo-security.json').read_bytes()).hexdigest()
    summary['rawSbomReportSha256'] = hashlib.sha256((args.directory / 'silo-sbom.cdx.json').read_bytes()).hexdigest()
    summary['reviewedSourceChecks'] = source_checks(policy)
    (args.directory / 'silo-security-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (args.directory / 'silo-fixed-fork.vex.json').write_text(json.dumps(vex, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
