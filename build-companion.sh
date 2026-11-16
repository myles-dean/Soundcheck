#!/bin/bash
# Builds Soundcheck Companion, the iPhone and iPad app.
#   ./build-companion.sh            build for the simulator
#   ./build-companion.sh device     build, install and open on the connected iPhone or iPad
#   ./build-companion.sh testflight archive and upload to App Store Connect (TestFlight); needs
#                                   the app's record in App Store Connect ("Soundcheck Companion",
#                                   bundle ID com.mylesdean.Soundcheck.Companion)
#   ./build-companion.sh test-mac   run a stand-in Mac (Tools/CompanionTest) to try the app against
#                                   without touching this Mac's sound
# Signing is automatic (Xcode's account for team 3N7MVP4K42).
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
BUILD="$PWD/build"
DERIVED="$BUILD/DerivedData.noindex"
SCHEME="SoundcheckCompanion"
BUNDLE="com.mylesdean.Soundcheck.Companion"

echo "→ Generating the Xcode project"
xcodegen generate --quiet

case "$MODE" in
"")
    xcodebuild -project Soundcheck.xcodeproj -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED" \
        -destination 'generic/platform=iOS Simulator' -quiet build CODE_SIGNING_ALLOWED=NO
    echo "✓ Built for the simulator"
    ;;
device)
    DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '(/available/ || / connected /) && /physical/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')
    [[ -n "$DEVICE" ]] || { echo "✗ No iPhone or iPad connected" >&2; exit 1; }
    xcodebuild -project Soundcheck.xcodeproj -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED" \
        -destination "id=$DEVICE" -allowProvisioningUpdates -quiet build
    xcrun devicectl device install app --device "$DEVICE" "$DERIVED/Build/Products/Debug-iphoneos/Soundcheck Companion.app" >/dev/null
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
    echo "✓ Installed and opened on $DEVICE"
    ;;
testflight)
    ARCHIVE="$BUILD/SoundcheckCompanion.xcarchive"
    rm -rf "$ARCHIVE"
    xcodebuild -project Soundcheck.xcodeproj -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
        -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet archive
    OPTIONS="$BUILD/companion-export.plist"
    cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>3N7MVP4K42</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$BUILD/companion-export" \
        -allowProvisioningUpdates
    echo "✓ Uploaded: it shows in App Store Connect › TestFlight after processing"
    ;;
test-mac)
    xcodebuild -project Soundcheck.xcodeproj -scheme CompanionTest -configuration Debug -derivedDataPath "$DERIVED" -quiet build
    exec "$DERIVED/Build/Products/Debug/CompanionTest" "${2:-1800}"
    ;;
*)
    echo "Usage: $0 [device|testflight|test-mac]" >&2
    exit 1
    ;;
esac
