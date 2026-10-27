#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p Converse.app/Contents/MacOS Converse.app/Contents/Resources
if [[ "${CONVERSE_SKIP_ICON_BUILD:-0}" != 1 ]]; then
  swift Sources/Icon.swift Converse.iconset
  iconutil -c icns Converse.iconset -o Converse.app/Contents/Resources/Converse.icns
elif [[ ! -f Converse.app/Contents/Resources/Converse.icns ]]; then
  print -u2 'No existing icon to reuse'; exit 1
fi
cp LICENSE Converse.app/Contents/Resources/LICENSE
mkdir -p .build
architectures=(${=CONVERSE_ARCHS:-$(uname -m)})
binaries=()
for architecture in "${architectures[@]}"; do
    swiftc -target "${architecture}-apple-macos14.0" Sources/main.swift Sources/MuseStatus.swift Sources/MuseQuota.swift Sources/MarkdownText.swift Sources/MuseConnection.swift Sources/ProviderSupport.swift Sources/ProviderTests.swift Sources/Workspace.swift Sources/WorkspaceTests.swift Sources/Switchboard.swift Sources/SwitchboardTests.swift Sources/Setup.swift Sources/SetupTests.swift -O -o ".build/Converse-${architecture}" -framework AppKit -framework SwiftUI -framework WebKit
    binaries+=(".build/Converse-${architecture}")
done
lipo -create "${binaries[@]}" -output Converse.app/Contents/MacOS/Converse
cat > Converse.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Converse</string>
<key>CFBundleIdentifier</key><string>local.richard.Converse</string>
<key>CFBundleIconFile</key><string>Converse</string>
<key>CFBundleName</key><string>Converse</string>
<key>CFBundleDisplayName</key><string>Converse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - Converse.app
printf 'Built %s/Converse.app\n' "$PWD"
