#!/usr/bin/env python3
"""Mutate authentic retained evidence to exercise the fixed-fork assessment boundary."""

import copy
import datetime
import gzip
import importlib.util
import json
from pathlib import Path
import sys
import unittest


sys.dont_write_bytecode = True
directory = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('storage_security', directory / 'check-preview-storage-security.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
with gzip.open(directory / 'fixtures/preview-storage-reviewed-evidence.json.gz', 'rb') as fixture:
    encoded = fixture.read(4 * 1024 * 1024)
DATA = json.loads(encoded)
NOW = datetime.datetime.fromisoformat(DATA['policy']['reviewedAt']) + datetime.timedelta(minutes=1)


class StorageSecurityBoundaries(unittest.TestCase):
    def values(self):
        return [copy.deepcopy(DATA[key]) for key in ('policy', 'scan', 'runtime', 'sbom', 'tool')]

    def rejects(self, change, code=1, now=NOW):
        values = self.values()
        change(values)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            gate.verify(*values, code, now=now)

    def test_authentic_subject_and_all_binary_controls_qualify(self):
        summary, vex = gate.verify(*self.values(), 1, now=NOW)
        self.assertEqual((1, 1, 0, 38), (summary['rawHighFindings'], summary['fixedInReviewedFork'],
                                       summary['unresolvedSecurityFindings'], summary['runtimeObservations']))
        self.assertEqual('fixed', vex['statements'][0]['status'])
        self.assertIn(DATA['policy']['packagePurl'], json.dumps(vex['statements'][0]['products']))

    def test_a_subject_change_cannot_inherit_the_assessment(self):
        changes = (
            lambda x: x[1].update(ArtifactName='pgsty/silo:latest'),
            lambda x: x[1]['Metadata'].update(ImageID='sha256:' + '0' * 64),
            lambda x: x[1]['Metadata']['ImageConfig'].update(architecture='arm64'),
            lambda x: x[2].update(actualSourceRevision='0' * 40),
            lambda x: x[1]['Results'][-1]['Vulnerabilities'][0].update(InstalledVersion='v9.9.9'),
            lambda x: x[3]['metadata']['component'].update(purl='pkg:golang/github.com/minio/minio'),
            lambda x: x[4].update(archiveSha256='0' * 64),
        )
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                self.rejects(change)

    def test_new_vulnerability_or_secret_remains_blocking(self):
        self.rejects(lambda x: x[1]['Results'][-1]['Vulnerabilities'].append(
            dict(x[1]['Results'][-1]['Vulnerabilities'][0], VulnerabilityID='CVE-2099-99999', Severity='CRITICAL')))
        self.rejects(lambda x: x[1]['Results'][-1].update(Secrets=[{'Severity': 'HIGH', 'RuleID': 'fixture-only'}]))

    def test_missing_or_empty_scan_coverage_is_rejected(self):
        self.rejects(lambda x: x[1]['Results'].pop(0))
        self.rejects(lambda x: x[1]['Results'][0].update(Packages=[]))

    def test_failed_or_missing_runtime_contracts_are_rejected(self):
        self.rejects(lambda x: x[2]['observations'].pop(14))
        self.rejects(lambda x: x[2]['observations'][17].update(errorCode='AccessDenied'))
        self.rejects(lambda x: x[2]['observations'][6].update(actualStatus=200))

    def test_cleanup_must_be_verified_boolean_evidence(self):
        for value in (False, 1, 'true'):
            with self.subTest(value=value):
                self.rejects(lambda x: x[2]['cleanup'].update(volumeRemoved=value))

    def test_tool_failure_cannot_be_classified_as_a_fixed_finding(self):
        self.rejects(lambda x: None, code=2)
        self.rejects(lambda x: None, code=0)

    def test_expired_assessment_and_stale_scan_are_rejected(self):
        expiry = datetime.datetime.fromisoformat(DATA['policy']['reviewExpiresAt'])
        self.rejects(lambda x: None, now=expiry + datetime.timedelta(seconds=1))
        self.rejects(lambda x: x[1].update(CreatedAt='2026-10-01T00:00:00Z'))

    def test_raw_advisory_disappearing_does_not_create_an_unresolved_finding(self):
        values = self.values()
        values[1]['Results'][-1]['Vulnerabilities'] = []
        summary, _ = gate.verify(*values, 0, now=NOW)
        self.assertEqual((0, 0), (summary['rawHighFindings'], summary['unresolvedSecurityFindings']))


if __name__ == '__main__':
    unittest.main()
