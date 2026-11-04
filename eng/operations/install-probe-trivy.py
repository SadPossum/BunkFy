#!/usr/bin/env python3
"""Install the reviewed Trivy release bytes without executing a remote shell script."""

import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import urllib.request


url = 'https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz'
expected = 'c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0'
with urllib.request.urlopen(url, timeout=120) as response:
    archive = response.read(64 * 1024 * 1024)
if hashlib.sha256(archive).hexdigest() != expected:
    raise RuntimeError('Trivy archive differs from the reviewed official release digest.')
destination = Path(os.environ['RUNNER_TEMP']) / 'reviewed-trivy-0.76.1'
destination.mkdir(mode=0o700)
with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
    matches = [member for member in package.getmembers() if member.name == 'trivy']
    if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 200 * 1024 * 1024:
        raise RuntimeError('Expected one bounded regular Trivy executable.')
    binary = destination / 'trivy'
    binary.write_bytes(package.extractfile(matches[0]).read())
    binary.chmod(0o700)
with open(os.environ['GITHUB_PATH'], 'a') as path:
    path.write(str(destination) + '\n')
evidence = Path('artifacts')
evidence.mkdir(exist_ok=True)
(evidence / 'tool-identity.json').write_text(json.dumps({
    'name': 'Trivy', 'version': '0.76.1', 'archiveSha256': expected,
    'officialReleaseAsset': 662254617, 'sourceUrl': url,
    'purpose': 'Local runner image vulnerability/secret analysis, no findings uploaded to an analysis service.'
}, indent=2) + '\n')
