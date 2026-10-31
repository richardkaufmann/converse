#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
source ./signing.sh
read -r app_version app_build < <(/usr/bin/python3 -c 'import json; v=json.load(open("VERSION.json")); print(v["version"], v["build"])')
signing_identity=$(converse_signing_identity)
app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
app="${app:A}"
# Never replace code or resources in a running app bundle.
converse_require_stopped_app "$app"
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
    swiftc -target "${architecture}-apple-macos14.0" Sources/main.swift Sources/ConfigurationAudit.swift Sources/AccountUsage.swift Sources/AgentSchedule.swift Sources/AgentScheduleTests.swift Sources/Jolly.swift Sources/JollyTests.swift Sources/ResponseImages.swift Sources/AgentResearch.swift Sources/AgentVoice.swift Sources/AgentConversation.swift Sources/AgentConversationTests.swift Sources/Agents.swift Sources/AgentDiscord.swift Sources/AgentDiscordRouter.swift Sources/AgentDiscordRouterTests.swift Sources/AgentDiscordTests.swift Sources/AgentRuntime.swift Sources/AgentUI.swift Sources/AgentTests.swift Sources/TranscriptStyle.swift Sources/HelpContent.swift Sources/Help.swift Sources/MuseStatus.swift Sources/MuseQuota.swift Sources/MarkdownText.swift Sources/MuseConnection.swift Sources/ProviderSupport.swift Sources/ProviderTests.swift Sources/ProviderLogo.swift Sources/PaneSizing.swift Sources/Workspace.swift Sources/WorkspaceTests.swift Sources/Switchboard.swift Sources/SwitchboardSupervision.swift Sources/SwitchboardTests.swift Sources/TranscriptExport.swift Sources/TranscriptExportTests.swift Sources/Setup.swift Sources/SetupTests.swift Sources/AccountLogin.swift Sources/AccountLoginTests.swift Sources/SidebarHover.swift Sources/SessionIdentity.swift Sources/SessionLogin.swift Sources/SessionSetup.swift Sources/SessionSetupTests.swift Sources/ImageAssist.swift Sources/MacImageTools.swift Sources/DeviceProtocol.swift Sources/DeviceCrypto.swift Sources/DeviceIdentity.swift Sources/DeviceSync.swift Sources/DeviceTransport.swift Sources/DeviceUI.swift Sources/GroupView.swift Sources/GroupTests.swift Sources/DeviceSyncTests.swift -O -o ".build/Converse-${architecture}" -framework AppKit -framework SwiftUI -framework WebKit -framework Network -framework CryptoKit -framework Security -framework AVFoundation
    binaries+=(".build/Converse-${architecture}")
done
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Converse"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Converse</string>
<key>CFBundleIdentifier</key><string>local.richard.Converse</string>
<key>CFBundleIconFile</key><string>Converse</string>
<key>CFBundleName</key><string>Converse</string>
<key>CFBundleDisplayName</key><string>Converse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$app_version</string>
<key>CFBundleVersion</key><string>$app_build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record your voice to transcribe an agent prompt with Meta. You review the text before sending.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Converse connects to your other Macs so you can view and control sessions across devices.</string>
<key>NSBonjourServices</key><array><string>_converse._tcp</string></array>
</dict></plist>
PLIST
/usr/bin/python3 scripts/build-help.py README.md "$app/Contents/Resources/Help"
if [[ "$signing_identity" == - ]]; then
  codesign --force --entitlements Resources/Converse.entitlements --sign - "$app"
  print 'Local ad-hoc signature (not a notarized release).'
else
  codesign --force --entitlements Resources/Converse.entitlements --options runtime --timestamp --sign "$signing_identity" "$app"
fi
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
