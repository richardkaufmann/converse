#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p Converse.app/Contents/MacOS Converse.app/Contents/Resources
swift Sources/Icon.swift Converse.iconset
iconutil -c icns Converse.iconset -o Converse.app/Contents/Resources/Converse.icns
swiftc Sources/main.swift Sources/MuseStatus.swift Sources/MuseQuota.swift -O -o Converse.app/Contents/MacOS/Converse -framework AppKit -framework SwiftUI -framework WebKit
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
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - Converse.app
printf 'Built %s/Converse.app\n' "$PWD"
