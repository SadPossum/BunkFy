#!/usr/bin/env python3
"""Build the checksum-pinned Preview PostgreSQL patch and require its exact config."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main():
    profile = json.loads((ROOT / '.gma/preview-infrastructure-profiles.json').read_text())['profiles']['maintained']
    build = profile['postgresBuild']
    recipe = ROOT / build['recipe']
    if hashlib.sha256(recipe.read_bytes()).hexdigest() != build['recipeSha256']:
        raise ValueError('Reviewed PostgreSQL patch recipe changed.')
    spec = importlib.util.spec_from_file_location('config_digest', ROOT / 'apps/backend/eng/operations/image-config-digest.py')
    identity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity)
    with tempfile.TemporaryDirectory(prefix='bunkfy-preview-pg-build-') as name:
        directory = Path(name)
        archive = directory / 'image.tar'
        subprocess.run(['docker', 'buildx', 'build', '--platform', 'linux/amd64', '--network', 'none',
            '--build-arg', 'SOURCE_DATE_EPOCH=' + str(build['sourceDateEpoch']), '--provenance=false',
            '--output', 'type=docker,rewrite-timestamp=true,dest=' + str(archive),
            '--file', str(recipe), '--tag', profile['images']['postgres'], str(directory)], check=True, timeout=300)
        if identity.config_digest(archive) != profile['configurationIds']['postgres']:
            raise ValueError('Rebuilt PostgreSQL bytes differ from the reviewed configuration; image was not loaded.')
        subprocess.run(['docker', 'load', '--input', str(archive)], check=True, timeout=120)
    print('Loaded the exact reviewed patched Preview PostgreSQL image.')

if __name__ == '__main__':
    main()
