#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
source ./signing.sh
if [[ -n "${CONVERSE_TEST_PROVIDER:-}" ]]; then
    case "$CONVERSE_TEST_PROVIDER" in Codex|Claude|Muse) ;; *) print -u2 'TEST provider must be Codex, Claude, or Muse'; exit 2;; esac
    [[ "${CONVERSE_DEMO:-0}" != 1 ]] || { print -u2 'TEST and Demo editions are separate'; exit 2; }
fi
read -r app_version app_build < <(/usr/bin/python3 -c 'import json; v=json.load(open("VERSION.json")); print(v["version"], v["build"])')
signing_identity=$(converse_signing_identity)
app="${CONVERSE_APP_OUTPUT:-$PWD/.build/Converse.app}"
app="${app:A}"
# Never replace code or resources in a running app bundle.
converse_require_stopped_app "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
icon_name=Converse
icon_source=Sources/Icon.swift
if [[ "${CONVERSE_TEST_PROVIDER:-}" == Codex ]]; then
  icon_name=ConverseTest
  icon_source=Sources/TestIcon.swift
fi
if [[ "${CONVERSE_SKIP_ICON_BUILD:-0}" != 1 ]]; then
  swift "$icon_source" "$icon_name.iconset"
  iconutil -c icns "$icon_name.iconset" -o "$app/Contents/Resources/$icon_name.icns"
elif [[ ! -f "$app/Contents/Resources/$icon_name.icns" ]]; then
  print -u2 'No existing icon to reuse'; exit 1
fi
mkdir -p "$app/Contents/Resources/ThirdParty"
cp Resources/ThirdParty/* "$app/Contents/Resources/ThirdParty/"
cp LICENSE LICENSING.md "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/ProviderLogos"
cp Resources/ProviderLogos/* "$app/Contents/Resources/ProviderLogos/"
cp Resources/Branding/Converse.png "$app/Contents/Resources/Converse.png"
mkdir -p .build
architectures=(${=CONVERSE_ARCHS:-$(uname -m)})
binaries=()
for architecture in "${architectures[@]}"; do
    swiftc -target "${architecture}-apple-macos14.0" Sources/main.swift Sources/ParkingLot.swift Sources/ParkingLotDocument.swift Sources/LotEditing.swift Sources/LotEditingTests.swift Sources/LotTransportTests.swift Sources/LotPortableExport.swift Sources/LotPortableExportTests.swift Sources/ParkingLotTags.swift Sources/ParkingLotEditor.swift Sources/ParkingLotLibrary.swift Sources/LotLinks.swift Sources/DemoReset.swift Sources/SettingsUI.swift Sources/ConfigurationAudit.swift Sources/PerformanceCapture.swift Sources/CharacterLatencyProbe.swift Sources/AccountUsage.swift Sources/AgentSchedule.swift Sources/AgentScheduleTests.swift Sources/Jolly.swift Sources/JollyTests.swift Sources/ResponseImages.swift Sources/AgentResearch.swift Sources/AgentInstructions.swift Sources/AgentPacing.swift Sources/AgentPaceTests.swift Sources/AgentRetry.swift Sources/AgentRetryTests.swift Sources/AgentObjectivePacing.swift Sources/AgentObjectivePacingTests.swift Sources/AgentVoice.swift Sources/AgentConversation.swift Sources/AgentConversationTests.swift Sources/Agents.swift Sources/AgentDiscord.swift Sources/AgentDiscordRouter.swift Sources/AgentDiscordRouterTests.swift Sources/AgentDiscordTests.swift Sources/AgentRuntime.swift Sources/AgentHomeAssistant.swift Sources/AgentHomeAssistantTests.swift Sources/AgentModels.swift Sources/AgentUI.swift Sources/AgentTests.swift Sources/TranscriptStyle.swift Sources/HelpContent.swift Sources/HelpVideo.swift Sources/Help.swift Sources/MuseStatus.swift Sources/MuseQuota.swift Sources/MarkdownText.swift Sources/MuseConnection.swift Sources/ProviderSupport.swift Sources/ProviderTests.swift Sources/ProviderLogo.swift Sources/ParkingLotShoe.swift Sources/TextSubstitutions.swift Sources/TextSubstitutionTests.swift Sources/PaneSizing.swift Sources/Workspace.swift Sources/WorkspaceTests.swift Sources/Switchboard.swift Sources/TranscriptSelfRead.swift Sources/TranscriptRetention.swift Sources/TranscriptSelfReadTests.swift Sources/TranscriptRetentionTests.swift Sources/SwitchboardSupervision.swift Sources/SwitchboardTests.swift Sources/TranscriptExport.swift Sources/TranscriptExportTests.swift Sources/ExportScrubber.swift Sources/ConverseExchange.swift Sources/ConverseExchangeTests.swift Sources/ProviderHandoff.swift Sources/ProviderHandoffTests.swift Sources/SessionTeaching.swift Sources/PaneTextSize.swift Sources/PaneTextScaling.swift Sources/PaneTextTests.swift Sources/SessionBatchTests.swift Sources/ImportRestore.swift Sources/ImportRestoreTests.swift Sources/Setup.swift Sources/AppSupport.swift Sources/FeedbackInvitation.swift Sources/GitHubBugReport.swift Sources/SupportNUX.swift Sources/AppSupportTests.swift Sources/SetupTests.swift Sources/AccountLogin.swift Sources/AccountLoginTests.swift Sources/SidebarHover.swift Sources/SessionSettingsMenu.swift Sources/SessionIdentity.swift Sources/SessionLogin.swift Sources/SessionSetup.swift Sources/SessionSetupTests.swift Sources/ImageAssist.swift Sources/SAMMask.swift Sources/ImageAssistTests.swift Sources/ImageSegments.swift Sources/MacImageTools.swift Sources/DeviceProtocol.swift Sources/DeviceCrypto.swift Sources/DeviceIdentity.swift Sources/DeviceSync.swift Sources/DeviceTransport.swift Sources/DeviceUI.swift Sources/GroupView.swift Sources/GroupTests.swift Sources/DeviceSyncTests.swift -O -o ".build/Converse-${architecture}" -framework AppKit -framework SwiftUI -framework WebKit -framework Network -framework CryptoKit -framework Security -framework AVFoundation
    binaries+=(".build/Converse-${architecture}")
done
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Converse"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Converse</string>
<key>CFBundleIdentifier</key><string>local.richard.Converse</string>
<key>CFBundleIconFile</key><string>$icon_name</string>
<key>CFBundleName</key><string>Converse</string>
<key>CFBundleDisplayName</key><string>Converse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$app_version</string>
<key>CFBundleVersion</key><string>$app_build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record your voice to transcribe an agent prompt with Meta. You review the text before sending.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Converse connects to your devices and, when you enable it, your Home Assistant server on the local network.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSBonjourServices</key><array><string>_converse._tcp</string></array>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.richard.converse.export</string>
<key>UTTypeDescription</key><string>Converse Conversations</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>converse</string></array><key>public.mime-type</key><array><string>application/vnd.converse+json</string></array></dict>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Converse Conversations</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Owner</string>
<key>LSItemContentTypes</key><array><string>local.richard.converse.export</string></array>
</dict></array>
</dict></plist>
PLIST
if [[ "${CONVERSE_NUX_PREVIEW:-0}" == 1 || "${CONVERSE_DEMO:-0}" == 1 || -n "${CONVERSE_TEST_PROVIDER:-}" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.richard.Converse.NUXPreview' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Converse Setup Preview' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Converse Setup Preview' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ConverseNUXPreview bool true' "$app/Contents/Info.plist"
fi
if [[ "${CONVERSE_DEMO:-0}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.richard.Converse.Demo' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Converse Demo' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Converse Demo' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ConverseDemo bool true' "$app/Contents/Info.plist"
fi
if [[ -n "${CONVERSE_TEST_PROVIDER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.richard.Converse.Test.$CONVERSE_TEST_PROVIDER" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $CONVERSE_TEST_PROVIDER Converse TEST" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $CONVERSE_TEST_PROVIDER Converse TEST" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ConverseTestProvider string $CONVERSE_TEST_PROVIDER" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ConverseAgentKeychainService string app.kaoslabs.Converse.Test.$CONVERSE_TEST_PROVIDER.Agent" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ConverseDeviceKeychainService string local.richard.Converse.Test.$CONVERSE_TEST_PROVIDER.device" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDocumentTypes:0:LSHandlerRank Alternate' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ConverseTestSource string $(git describe --always --dirty)" "$app/Contents/Info.plist"
fi
# Dedicated performance experiments must honor their disposable data directory.
# Ordinary persistent TEST editions keep their existing profile behavior.
if [[ "${CONVERSE_CHARACTER_PROBE_BUILD:-0}" == 1 ]]; then
  [[ "${CONVERSE_TEST_PROVIDER:-}" == Codex ]] || { print -u2 'Character probe requires a Codex TEST build'; exit 2; }
  /usr/libexec/PlistBuddy -c 'Delete :ConverseNUXPreview' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.richard.Converse.Test.CharacterProbe' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Converse Character Probe TEST' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Converse Character Probe TEST' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :ConverseAgentKeychainService local.richard.Converse.Test.CharacterProbe.Agent' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :ConverseDeviceKeychainService local.richard.Converse.Test.CharacterProbe.device' "$app/Contents/Info.plist"
fi
/usr/bin/python3 scripts/build-help.py README.md "$app/Contents/Resources/Help"
if [[ "$signing_identity" == - ]]; then
  codesign --force --entitlements Resources/Converse.entitlements --sign - "$app"
  print 'Local ad-hoc signature (not a notarized release).'
else
  codesign --force --entitlements Resources/Converse.entitlements --options runtime --timestamp --sign "$signing_identity" "$app"
fi
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
