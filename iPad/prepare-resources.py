#!/usr/bin/env python3
"""Xcode phase: one version source, shared README Help, iPad-specific Info."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
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
# Noise uses Apple CryptoKit primitives; URLSession uses Apple's HTTPS stack.
# This describes exempt encryption, not an absence of encryption. Revisit if
# a future dependency supplies cryptography outside Apple's operating system.
info['ITSAppUsesNonExemptEncryption'] = False
with (output / 'Converse-Info.plist').open('wb') as file: plistlib.dump(info, file)
resources = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
shutil.copytree(root/'Resources/ProviderLogos', resources/'ProviderLogos', dirs_exist_ok=True)
subprocess.run(['/usr/bin/python3', str(root/'scripts/build-help.py'), str(root/'README.md'), str(resources/'Help')], check=True)
