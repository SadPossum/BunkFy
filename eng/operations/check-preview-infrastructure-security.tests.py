#!/usr/bin/env python3
"""Exercise assessment boundaries with mutations of authenticated retained reports."""

import copy
import datetime
import importlib.util
import json
from pathlib import Path
import sys
import unittest


sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('infrastructure_security', HERE / 'check-preview-infrastructure-security.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
POLICY = json.loads((gate.ROOT / '.gma/preview-infrastructure-review.json').read_text())
PROFILES = json.loads((gate.ROOT / '.gma/preview-infrastructure-profiles.json').read_text())
DATA = gate.load_fixture(POLICY)
# Keep every original raw report byte unchanged. Only the unit-test policy clock
# is shifted into their shared two-hour window; this is not a fresh scan claim.
NOW = max(datetime.datetime.fromisoformat(value['CreatedAt'].replace('Z', '+00:00'))
          for value in DATA['scans'].values()) + datetime.timedelta(minutes=1)


class InfrastructureSecurityBoundaries(unittest.TestCase):
    def values(self):
        policy = copy.deepcopy(POLICY)
        policy['reviewedAt'] = (NOW - datetime.timedelta(minutes=1)).isoformat()
        policy['reviewExpiresAt'] = (NOW + datetime.timedelta(days=29)).isoformat()
        original = {value['osv']['id']: value['osv'] for value in gate.records(DATA['helperRawReport']) if 'osv' in value}
        advisories = {key: original[key] for key in policy['postgres']['advisorySha256']}
        codes = {key: int(any(result.get('Vulnerabilities') for result in scan['Results']))
                 for key, scan in DATA['scans'].items()}
        return copy.deepcopy([policy, PROFILES, DATA['scans'], DATA['context'], DATA['tool'],
                              DATA, advisories, codes, DATA['context']['sourceCommit']])

    def rejects(self, mutation, now=NOW):
        values = self.values()
        mutation(values)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            gate.verify(*values, now=now)

    def test_actual_raw_reports_and_qualified_context_pass(self):
        result = gate.verify(*self.values(), now=NOW)
        self.assertEqual((26, 0, 27), (result['rawHighCriticalFindings'], result['unresolvedSecurityFindings'],
                                     result['advisoriesRevalidated']))
        self.assertEqual('CVE-2026-61801', result['postgresContextCve'])

    def test_every_image_requires_complete_subject_platform_and_inventory(self):
        for name in DATA['scans']:
            changes = [lambda x: x[2][name].update(ArtifactName='unreviewed:latest'),
                       lambda x: x[2][name]['Metadata'].update(ImageID='sha256:' + '0' * 64),
                       lambda x: x[2][name]['Metadata']['ImageConfig'].update(architecture='arm64'),
                       lambda x: x[2][name]['Metadata'].update(RepoDigests=[]),
                       lambda x: x[2][name].update(Results=[]),
                       lambda x: x[2][name]['Results'][0].update(Packages=[])]
            for index, change in enumerate(changes):
                with self.subTest(image=name, mutation=index):
                    self.rejects(change)

    def test_local_patch_requires_hashed_descriptors_runtime_binding_and_fixed_package(self):
        self.rejects(lambda x: x[5]['imageDescriptors'].update(postgres={}))
        key = next(iter(DATA['imageDescriptors']['postgres']))
        self.rejects(lambda x: x[5]['imageDescriptors']['postgres'].update({key: '{}'}))
        self.rejects(lambda x: x[3].update(runtimeImageId='sha256:' + '0' * 64))
        self.rejects(lambda x: x[1]['profiles']['maintained']['postgresBuild'].update(recipeSha256='0' * 64))
        self.rejects(lambda x: next(p for r in x[2]['postgres']['Results'] for p in r.get('Packages', [])
                                  if p['Name'] == 'libxslt').update(Version='1.1.43-r3'))
        self.rejects(lambda x: x[2]['postgres']['Metadata'].update(RepoDigests=[]))

    def test_new_vulnerabilities_and_secrets_block_every_image(self):
        finding = DATA['scans']['postgres']['Results'][-1]['Vulnerabilities'][0]
        for name in DATA['scans']:
            with self.subTest(image=name, kind='vulnerability'):
                self.rejects(lambda x: x[2][name]['Results'][0].update(
                    Vulnerabilities=[dict(finding, VulnerabilityID='CVE-2099-99999')]))
            with self.subTest(image=name, kind='secret'):
                self.rejects(lambda x: x[2][name]['Results'][0].update(Secrets=[{'Severity': 'HIGH'}]))

    def test_known_cve_cannot_move_package_version_or_duplicate(self):
        for key, value in [('InstalledVersion', 'v9.9.9'), ('PkgName', 'other-library')]:
            with self.subTest(key=key):
                self.rejects(lambda x: x[2]['postgres']['Results'][-1]['Vulnerabilities'][0].update({key: value}))
        self.rejects(lambda x: x[2]['postgres']['Results'][-1]['Vulnerabilities'].append(
            x[2]['postgres']['Results'][-1]['Vulnerabilities'][0]))

    def test_stale_future_expired_and_failed_scans_are_rejected(self):
        self.rejects(lambda x: x[2]['postgres'].update(CreatedAt=(NOW - datetime.timedelta(hours=3)).isoformat()))
        self.rejects(lambda x: x[2]['postgres'].update(CreatedAt=(NOW + datetime.timedelta(minutes=1)).isoformat()))
        self.rejects(lambda x: x[0].update(reviewExpiresAt=NOW.isoformat()))
        for code in (0, 2, '1', None):
            with self.subTest(code=code):
                self.rejects(lambda x: x[7].update(postgres=code))
        self.rejects(lambda x: x[4].update(archiveSha256='0' * 64))

    def test_actual_process_profile_and_bounded_inputs_are_mandatory(self):
        changes = [lambda x: x[3].update(sourceCommit='a' * 40),
                   lambda x: x[3]['execution'].update(user='0:0'),
                   lambda x: x[3]['execution'].update(readOnly=False),
                   lambda x: x[3]['execution'].update(readOnly=1),
                   lambda x: x[3]['execution'].update(capDrop=[]),
                   lambda x: x[3]['execution'].update(securityOptions=[]),
                   lambda x: x[3]['process'].update(uids=['0'] * 4),
                   lambda x: x[3]['process'].update(effectiveCapabilities='1'),
                   lambda x: x[3]['process'].update(noNewPrivileges='true'),
                   lambda x: x[3].update(bindMounts=1),
                   lambda x: x[3].update(onlyDataVolume=False),
                   lambda x: x[3].update(networkInternal=False),
                   lambda x: x[3].update(publishedPorts=1),
                   lambda x: x[3]['helperInputFiles'][0].update(mode='666'),
                   lambda x: x[3]['helperInputFiles'][1].update(size=99_000_000),
                   lambda x: x[3].update(entrypointSha256='0' * 64)]
        for index, change in enumerate(changes):
            with self.subTest(mutation=index):
                self.rejects(change)

    def test_cleanup_requires_boolean_true(self):
        for value in (False, 'true', 1):
            with self.subTest(value=value):
                self.rejects(lambda x: x[3]['cleanup'].update(ownedVolumesRemoved=value))

    def test_changed_primary_advisory_forces_reanalysis(self):
        identity = next(iter(POLICY['postgres']['advisorySha256']))
        self.rejects(lambda x: x[6][identity].update(details='changed primary advisory'))
        self.rejects(lambda x: x[6].pop(identity))

    def test_helper_proof_and_fixture_cannot_be_replaced_with_a_summary(self):
        self.rejects(lambda x: x[5].update(helperRawReport='{}'))
        self.rejects(lambda x: x[5]['helperSummary'].update(analyzerSha256='0' * 64))
        altered = copy.deepcopy(POLICY)
        altered['fixtureSha256'] = '0' * 64
        with self.assertRaises(ValueError):
            gate.load_fixture(altered)

    def test_advisory_disappearing_from_raw_scan_does_not_invent_a_vulnerability(self):
        values = self.values()
        values[2]['postgres']['Results'][-1]['Vulnerabilities'] = []
        values[7]['postgres'] = 0
        result = gate.verify(*values, now=NOW)
        self.assertEqual(0, result['rawHighCriticalFindings'])


if __name__ == '__main__':
    unittest.main()
