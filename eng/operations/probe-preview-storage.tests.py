#!/usr/bin/env python3
"""Offline SigV4 regressions; no HTTP requests or Docker allocations."""

import datetime
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('storage_probe', Path(__file__).with_name('probe-preview-storage.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FixedDate(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2013, 5, 24, tzinfo=datetime.timezone.utc)


class Response:
    status = 200
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, maximum):
        return b'fixture'


class S3SigningContracts(unittest.TestCase):
    def capture(self, method='PUT', path='/fixture/object.bin', headers=None, **options):
        # These are AWS's published, non-secret documentation example credentials.
        key = options.pop('key', 'fixture-access-key')
        password = options.pop('password', 'fixture-signing-key')
        endpoint = options.pop('endpoint', 'http://127.0.0.1:19000')
        with patch.object(probe.HTTP, 'open', return_value=Response()) as opened, \
                patch.object(probe.datetime, 'datetime', FixedDate):
            result = probe.request(endpoint, key, password, method, path, headers=headers, **options)
        self.assertEqual((200, b'fixture', {}), result)
        return opened.call_args.args[0]

    def test_official_aws_range_vector_matches_the_published_signature(self):
        # AWS S3 SigV4 GET Object example, including Range in the signed headers:
        # https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
        request = self.capture('GET', '/test.txt', {'Range': 'bytes=0-9'},
            endpoint='https://examplebucket.s3.amazonaws.com',
            key='AKIAIOSFODNN7EXAMPLE', password='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY')
        self.assertTrue(request.get_header('Authorization').endswith(
            'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41'))

    def test_official_aws_empty_query_value_vector_is_preserved(self):
        request = self.capture('GET', '/?lifecycle',
            endpoint='https://examplebucket.s3.amazonaws.com',
            key='AKIAIOSFODNN7EXAMPLE', password='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY')
        self.assertTrue(request.get_header('Authorization').endswith(
            'Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543'))

    def test_all_metadata_and_content_md5_headers_are_authenticated(self):
        headers = {'x-amz-meta-file-name': 'backup-canary.bin',
            'X-Amz-Meta-Kind': 'synthetic-recovery-canary', 'Content-MD5': 'fixture-md5'}
        request = self.capture(headers=headers, body=b'fixture-object-bytes')
        authorization = request.get_header('Authorization')
        signed = authorization.split('SignedHeaders=', 1)[1].split(',', 1)[0].split(';')
        self.assertEqual(['content-md5', 'host', 'x-amz-content-sha256', 'x-amz-date',
            'x-amz-meta-file-name', 'x-amz-meta-kind'], signed)

    def test_metadata_tampering_changes_the_signature(self):
        before = self.capture(headers={'x-amz-meta-kind': 'synthetic-recovery-canary'})
        after = self.capture(headers={'x-amz-meta-kind': 'changed-canary'})
        self.assertNotEqual(before.get_header('Authorization'), after.get_header('Authorization'))

    def test_header_case_and_canonical_whitespace_are_equivalent(self):
        first = self.capture(headers={'X-Amz-Meta-File-Name': '  synthetic   canary.bin  '})
        second = self.capture(headers={'x-amz-meta-file-name': 'synthetic canary.bin'})
        self.assertEqual(first.get_header('Authorization'), second.get_header('Authorization'))

    def test_unsigned_denial_probe_and_deliberately_bad_signature_remain_distinct(self):
        unsigned = self.capture(signed=False)
        self.assertIsNone(unsigned.get_header('Authorization'))
        good = self.capture(headers={'x-amz-meta-kind': 'synthetic-recovery-canary'})
        bad = self.capture(headers={'x-amz-meta-kind': 'synthetic-recovery-canary'}, bad_signature=True)
        original = good.get_header('Authorization').split('Signature=', 1)[1]
        invalid = bad.get_header('Authorization').split('Signature=', 1)[1]
        self.assertNotEqual(original[0], invalid[0])
        self.assertEqual(original[1:], invalid[1:])

    def test_caller_cannot_override_the_owned_signing_headers(self):
        request = self.capture(headers={'Host': 'untrusted.invalid', 'X-Amz-Date': 'untrusted-date',
            'X-Amz-Content-Sha256': 'untrusted-hash', 'Authorization': 'untrusted-authority'})
        normal = self.capture()
        self.assertEqual(normal.get_header('Authorization'), request.get_header('Authorization'))
        self.assertEqual('127.0.0.1:19000', request.get_header('Host'))


if __name__ == '__main__':
    unittest.main()
