#!/usr/bin/env python3
"""Validate committed inputs without requiring Xcode or third-party Python packages."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT / 'Irar.xcodeproj/project.pbxproj').read_text()
ids = re.findall(r'^\s+([A-F0-9]{24}) = \{', project, re.M)
assert len(ids) == len(set(ids)), 'duplicate Xcode object identifiers'
for reference in re.findall(r'\b([A-F0-9]{24})\b', project):
    assert reference in ids, f'missing Xcode object {reference}'
for source in list((ROOT / 'Irar').rglob('*.swift')) + list((ROOT / 'Irar').rglob('*.c')):
    relative = source.relative_to(ROOT / 'Irar').as_posix()
    assert f'path = "{relative}";' in project, f'missing source reference: {relative}'
assert 'Irar/Irar-Bridging-Header.h' in project
assert '$(TARGET_TEMP_DIR)/libarchive/libarchive.a' in project
assert 'Build libarchive' in project
assert 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;' in project
with (ROOT / 'Irar/Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert info['UIFileSharingEnabled'] and info['LSSupportsOpeningDocumentsInPlace']
assert info['CFBundlePackageType'] == 'APPL'
scheme = ET.parse(ROOT / 'Irar.xcodeproj/xcshareddata/xcschemes/Irar.xcscheme')
assert scheme.find('.//BuildableReference').attrib['BlueprintIdentifier'] in ids
for asset in (ROOT / 'Irar/Assets.xcassets').rglob('Contents.json'):
    contents = json.loads(asset.read_text())
    for item in contents.get('images', []):
        if 'filename' in item: assert (asset.parent / item['filename']).is_file()
icon = (ROOT / 'Irar/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()
assert icon[:8] == b'\x89PNG\r\n\x1a\n'
assert struct.unpack('>II', icon[16:24]) == (1024, 1024)
assert icon[25] == 2, 'app icon must be opaque RGB'
package = ROOT / 'vendor/libarchive-3.8.7.tar.xz'
assert hashlib.sha256(package.read_bytes()).hexdigest() == 'd3a8ba457ae25c27c84fd2830a2efdcc5b1d40bf585d4eb0d35f47e99e5d4774'
workflow = (ROOT / 'codemagic.yaml').read_text()
assert 'CODE_SIGNING_ALLOWED=NO' in workflow and 'mac_mini_m2' in workflow
assert 'tests/run-tests.sh' in workflow and 'scripts/package-ipa.sh' in workflow
print('PASS: Xcode source IDs/references, shared scheme, plist, opaque app icon, pinned source hash and Codemagic inputs')
