#!/usr/bin/env python3
"""Xcode phase: one version source, shared README Help, iPad-specific Info."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
root = Path(__file__).resolve().parents[1]
version = json.loads((root / 'VERSION.json').read_text())
output = Path(os.environ['DERIVED_FILE_DIR']); output.mkdir(parents=True, exist_ok=True)
info = {
    'CFBundleDevelopmentRegion': 'en', 'CFBundleDisplayName': 'Converse',
    'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': 'Converse', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version['version'], 'CFBundleVersion': str(version['build']),
    'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '18.0',
    'NSLocalNetworkUsageDescription': 'Connect securely to Converse on your computers to view and control your conversations.',
    'NSBonjourServices': ['_converse._tcp'],
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
    'UILaunchScreen': {},
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    'UIRequiresFullScreen': False,
}
# Noise provides application-level encryption. Export classification must be
# answered honestly in App Store Connect; do not claim "no encryption" here.
with (output / 'Converse-Info.plist').open('wb') as file: plistlib.dump(info, file)
resources = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
subprocess.run(['/usr/bin/python3', str(root/'scripts/build-help.py'), str(root/'README.md'), str(resources/'Help')], check=True)
