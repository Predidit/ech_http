#!/usr/bin/env python3
"""Update reviewed Release pins; build hooks never call this maintainer tool."""
import json
from pathlib import Path
import re
import subprocess
import sys

TARGETS = {
    'win32': ['windows-x64', 'windows-arm64', 'windows-ia32'],
    'darwin': ['macos-x64', 'macos-arm64', 'ios-arm64-device', 'ios-arm64-simulator', 'ios-x64-simulator'],
    'android': ['android-arm', 'android-arm64', 'android-x64', 'android-ia32'],
    'linux': ['linux-x64', 'linux-arm64'],
}


def main():
    if not sys.argv[1:]:
        raise SystemExit('Usage: python tool/update_prebuilt.py win32=v0.1.0 darwin=v0.1.1 android=v0.1.0 linux=v0.1.0')
    path = Path(__file__).resolve().parents[1] / 'lib/src/build_support/dependencies.json'
    manifest = json.loads(path.read_text())
    targets = manifest.setdefault('targets', {})
    for item in sys.argv[1:]:
        family, tag = item.split('=', 1)
        if family not in TARGETS or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
            raise SystemExit(f'Invalid family or version: {item}')
        repo = f'Predidit/libechhttp-{family}-build'
        release = json.loads(subprocess.check_output([
            'gh', 'api', f'repos/{repo}/releases/tags/{tag}',
        ], text=True, encoding='utf-8'))
        if release['draft'] or release['tag_name'] != tag:
            raise SystemExit('Expected a published versioned release')
        assets = {asset['name']: asset for asset in release['assets']}
        for target in TARGETS[family]:
            name = f'libechhttp-deps-{tag}-{target}.zip'
            asset = assets[name]
            digest = asset.get('digest', '')
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
                raise SystemExit(f'Missing GitHub SHA-256 digest: {name}')
            url = f'https://github.com/{repo}/releases/download/{tag}/{name}'
            if asset['browser_download_url'] != url:
                raise SystemExit(f'Unexpected release asset URL: {name}')
            targets[target] = {'release': tag, 'url': url, 'sha256': digest.removeprefix('sha256:')}
        print(f'Pinned {repo}@{tag}: {len(TARGETS[family])} targets')
    manifest['targets'] = dict(sorted(targets.items()))
    path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
