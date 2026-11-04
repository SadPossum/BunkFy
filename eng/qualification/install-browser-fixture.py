#!/usr/bin/env python3
"""Install only the three exact lockfile browser packages; never rebuild the web app."""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import urllib.parse
import urllib.request


def require(condition, message):
    if not condition:
        raise ValueError(message)


def lock_packages(candidate):
    web = candidate / 'apps/web'
    package = json.loads((web / 'package.json').read_text())
    version = package['devDependencies']['@playwright/test']
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'The candidate must pin the exact browser tool version.')
    lock = (web / 'pnpm-lock.yaml').read_text()
    result = []
    for name in ('@playwright/test', 'playwright', 'playwright-core'):
        header = re.escape(name + '@' + version)
        matches = re.findall(r"(?m)^  '?" + header + r"'?:\n    resolution: \{integrity: (sha512-[A-Za-z0-9+/=]+)\}", lock)
        require(len(matches) == 1, 'Exact browser package integrity is missing or ambiguous: ' + name)
        result.append({'name': name, 'version': version, 'integrity': matches[0]})
    return result


def fetch(url, bound):
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == 'https' and parsed.hostname == 'registry.npmjs.org' and not parsed.username,
            'Only the official locked npm package source is allowed.')
    with urllib.request.urlopen(url, timeout=60) as response:
        require(urllib.parse.urlsplit(response.url).hostname == 'registry.npmjs.org', 'Package source redirected outside npm.')
        value = response.read(bound + 1)
    require(len(value) <= bound, 'Browser package response exceeds its size bound.')
    return value


def install(candidate, records):
    root = candidate / 'apps/web/node_modules'
    root.mkdir(exist_ok=True, mode=0o700)
    for record in records:
        name, version = record['name'], record['version']
        destination = root / name
        require(not destination.exists() and not destination.is_symlink(), 'Refusing to replace an existing browser package.')
        metadata = json.loads(fetch('https://registry.npmjs.org/' + name + '/' + version, 2_000_000))
        require(metadata['name'] == name and metadata['version'] == version
                and metadata['dist']['integrity'] == record['integrity'], 'Official package differs from the candidate lock.')
        archive = fetch(metadata['dist']['tarball'], 8_000_000)
        require('sha512-' + base64.b64encode(hashlib.sha512(archive).digest()).decode() == record['integrity'],
                'Browser package archive failed the lockfile integrity check.')
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
            members = package.getmembers()
            require(len(members) <= 3000 and sum(value.size for value in members) <= 50_000_000,
                    'Browser package extraction exceeds its bound.')
            destination.mkdir(parents=True, mode=0o700)
            seen = set()
            for member in members:
                parts = PurePosixPath(member.name).parts
                require(parts and parts[0] == 'package' and '..' not in parts and not member.name.startswith('/')
                        and (member.isfile() or member.isdir()), 'Unsafe package path/link rejected.')
                relative = Path(*parts[1:])
                if not parts[1:]:
                    require(member.isdir(), 'Package root must be a directory.')
                    continue
                require(relative not in seen, 'Duplicate package entry rejected.')
                seen.add(relative)
                target = destination / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o700)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    with target.open('xb') as output:
                        output.write(package.extractfile(member).read())
                    target.chmod(0o700 if member.mode & 0o111 else 0o600)
        require(json.loads((destination / 'package.json').read_text())['version'] == version,
                'Extracted package version mismatch.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--verify-lock-only', action='store_true')
    args = parser.parse_args()
    records = lock_packages(args.candidate.resolve())
    if not args.verify_lock_only:
        install(args.candidate.resolve(), records)
    print(json.dumps({'packages': records, 'installed': not args.verify_lock_only,
                      'scope': 'Locked browser tooling only; compiled application bytes are unchanged.'}))
