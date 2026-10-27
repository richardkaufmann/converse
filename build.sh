#!/bin/zsh
set -eu
cd "${0:A:h}"
app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
app="${app:A}"
# Never replace a running bundle: ad-hoc signatures change on every build and
# invalidate macOS privacy consent for the app and its child tools.
if ps -axo comm= | /usr/bin/grep -Fxq "$app/Contents/MacOS/Converse"; then
  print -u2 "Refusing to rebuild a running app: $app"
  print -u2 'Quit that app first, or choose a different CONVERSE_APP_OUTPUT.'
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "${CONVERSE_SKIP_ICON_BUILD:-0}" != 1 ]]; then
  swift Sources/Icon.swift Converse.iconset
  iconutil -c icns Converse.iconset -o "$app/Contents/Resources/Converse.icns"
elif [[ ! -f "$app/Contents/Resources/Converse.icns" ]]; then
  print -u2 'No existing icon to reuse'; exit 1
fi
cp LICENSE "$app/Contents/Resources/LICENSE"
mkdir -p "$app/Contents/Resources/ProviderLogos"
cp Resources/ProviderLogos/* "$app/Contents/Resources/ProviderLogos/"
mkdir -p .build
architectures=(${=CONVERSE_ARCHS:-$(uname -m)})
binaries=()
for architecture in "${architectures[@]}"; do
    swiftc -target "${architecture}-apple-macos14.0" Sources/main.swift Sources/MuseStatus.swift Sources/MuseQuota.swift Sources/MarkdownText.swift Sources/MuseConnection.swift Sources/ProviderSupport.swift Sources/ProviderTests.swift Sources/ProviderLogo.swift Sources/PaneSizing.swift Sources/Workspace.swift Sources/WorkspaceTests.swift Sources/Switchboard.swift Sources/SwitchboardTests.swift Sources/TranscriptExport.swift Sources/TranscriptExportTests.swift Sources/Setup.swift Sources/SetupTests.swift Sources/AccountLogin.swift Sources/AccountLoginTests.swift Sources/SidebarHover.swift Sources/SessionIdentity.swift Sources/SessionLogin.swift Sources/SessionSetup.swift Sources/SessionSetupTests.swift Sources/DeviceProtocol.swift Sources/DeviceCrypto.swift Sources/DeviceIdentity.swift Sources/DeviceSync.swift Sources/DeviceTransport.swift Sources/DeviceUI.swift Sources/DeviceSyncTests.swift -O -o ".build/Converse-${architecture}" -framework AppKit -framework SwiftUI -framework WebKit -framework Network -framework CryptoKit -framework Security
    binaries+=(".build/Converse-${architecture}")
done
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Converse"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Converse</string>
<key>CFBundleIdentifier</key><string>local.richard.Converse</string>
<key>CFBundleIconFile</key><string>Converse</string>
<key>CFBundleName</key><string>Converse</string>
<key>CFBundleDisplayName</key><string>Converse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>13</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Converse connects to your other Macs so you can view and control sessions across devices.</string>
<key>NSBonjourServices</key><array><string>_converse._tcp</string></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf 'Built %s\n' "$app"
