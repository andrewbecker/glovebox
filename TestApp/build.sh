#!/bin/sh
# Builds TestApp for the iOS Simulator without an Xcode project:
#   TestApp/build.sh        -> TestApp/build/TestApp.app
# Then: install_app with that path, and launch_app dev.glovebox.TestApp.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app="$here/build/TestApp.app"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
version=$(xcrun --sdk iphonesimulator --show-sdk-version)
arch=$(uname -m)

rm -rf "$app"
mkdir -p "$app"

xcrun --sdk iphonesimulator swiftc \
    -target "$arch-apple-ios$version-simulator" \
    -sdk "$sdk" \
    -parse-as-library \
    -Onone -g \
    "$here"/Sources/*.swift \
    -o "$app/TestApp"

cat > "$app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.glovebox.TestApp</string>
    <key>CFBundleName</key><string>TestApp</string>
    <key>CFBundleDisplayName</key><string>glovebox Test</string>
    <key>CFBundleExecutable</key><string>TestApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
    <key>MinimumOSVersion</key><string>$version</string>
    <key>UIDeviceFamily</key><array><integer>1</integer></array>
    <key>UILaunchScreen</key><dict/>
    <key>UIApplicationSceneManifest</key>
    <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict>
</plist>
EOF

codesign --force --sign - "$app" >/dev/null 2>&1
echo "$app"
