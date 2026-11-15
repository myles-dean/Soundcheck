#!/bin/bash
# Builds Soundcheck.app.
#   ./build.sh           build only, into ./build
#   ./build.sh install   build, install to /Applications and (re)launch, leaving no other copy behind
#   ./build.sh release   Developer ID build (hardened runtime) packaged as build/Soundcheck.dmg;
#                        with NOTARY_PROFILE=<notarytool keychain profile> it's notarized and stapled.
#                        Also writes build/appcast.xml (the update feed): attach it to the GitHub
#                        release along with the DMG; and build/Soundcheck-Chrome-Extension-<v>.zip,
#                        the browser extension for the Chrome Web Store. Signing it uses the update key in the login
#                        Keychain (account "Soundcheck"); macOS may ask to allow that.
# Needs Xcode 26+ and xcodegen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
NAME="Soundcheck"
BUILD="$PWD/build"
APP="$BUILD/$NAME.app"
# ".noindex" keeps Spotlight (and Launchpad) away from build products.
DERIVED="$BUILD/DerivedData.noindex"
PRODUCTS="$DERIVED/Build/Products/Release"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "→ Generating the Xcode project"
xcodegen generate --quiet

SIGNING=()
if [[ "$MODE" == "release" ]]; then
    # No get-task-allow (Xcode adds it for debugging; notarization rejects it).
    SIGNING=(CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp
             CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

echo "→ Building"
xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" -configuration Release \
    -derivedDataPath "$DERIVED" -destination "platform=macOS" -quiet \
    ${SIGNING[@]+"${SIGNING[@]}"} build
if [[ "$MODE" == "release" ]]; then
    # Sparkle's helpers come ad-hoc signed, which notarization refuses: sign them (inside out) as
    # Sparkle's documentation describes, then the app again around them.
    SPARKLE="$PRODUCTS/$NAME.app/Contents/Frameworks/Sparkle.framework"
    sign() { codesign --force --sign "Developer ID Application" --options runtime --timestamp "$@"; }
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
    sign --preserve-metadata=entitlements "$PRODUCTS/$NAME.app"
fi

if [[ "$MODE" != "install" ]]; then
    rm -rf "$APP"
    ditto "$PRODUCTS/$NAME.app" "$APP"
    echo "✓ Built $APP"
fi

if [[ "$MODE" == "release" ]]; then
    if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
        echo "✗ The release build still has the get-task-allow entitlement" >&2; exit 1
    fi
    echo "→ Disk image"
    DMG="$BUILD/$NAME.dmg"
    STAGE="$BUILD/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$NAME.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
    rm -rf "$STAGE"
    codesign --force --sign "Developer ID Application" --timestamp "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "→ Notarizing (a few minutes)"
        RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)
        if ! grep -q "status: Accepted" <<< "$RESULT"; then
            SUBMISSION=$(awk '/^  id:/ {print $2; exit}' <<< "$RESULT")
            echo "✗ Notarization failed. Apple's log:" >&2
            xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
            exit 1
        fi
        xcrun stapler staple "$DMG"
        echo "✓ Notarized and stapled"
    else
        echo "  Not notarized. Run with NOTARY_PROFILE=<profile> to notarize."
    fi
    echo "✓ $DMG"

    echo "→ Update feed"
    TOOLS="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
    # sparkle:edSignature="…" length="…", for the DMG exactly as it'll be uploaded (after stapling).
    SIGNATURE=$("$TOOLS/sign_update" --account Soundcheck "$DMG")
    cat > "$BUILD/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Soundcheck</title>
    <link>https://github.com/myles-dean/Soundcheck</link>
    <item>
      <title>Soundcheck $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/myles-dean/Soundcheck/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/myles-dean/Soundcheck/releases/download/v$VERSION/Soundcheck.dmg" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
    echo "✓ $BUILD/appcast.xml (attach it to the v$VERSION release with the DMG)"

    echo "→ Chrome Web Store package"
    # The extension as the store takes it: without the "key" that fixes the ID for Load unpacked
    # (the store gives it its own ID).
    STAGE="$BUILD/chrome-extension"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp Extension/Shared/* "$STAGE/"
    EXTENSION_VERSION=$(/usr/bin/python3 -c 'import json,sys; m=json.load(open("Extension/Chromium/manifest.json")); m.pop("key",None); json.dump(m, open(sys.argv[1],"w"), indent=2); print(m["version"])' "$STAGE/manifest.json")
    ZIP="$BUILD/Soundcheck-Chrome-Extension-$EXTENSION_VERSION.zip"
    rm -f "$ZIP"
    (cd "$STAGE" && zip -q -r -X "$ZIP" .)
    rm -rf "$STAGE"
    echo "✓ $ZIP (upload it in the Chrome Web Store Developer Dashboard when the extension changes)"
fi

if [[ "$MODE" == "install" ]]; then
    echo "→ Installing to /Applications"
    pkill -x "$NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$NAME.app"
    ditto "$PRODUCTS/$NAME.app" "/Applications/$NAME.app"
    # Keep only the installed copy, and forget the build products in Launch Services.
    for leftover in "$PRODUCTS/$NAME.app" "$APP"; do
        "$LSREGISTER" -u "$leftover" 2>/dev/null || true
        rm -rf "$leftover"
    done
    "$LSREGISTER" -f "/Applications/$NAME.app"
    open "/Applications/$NAME.app" --args --background
    echo "✓ Installed and launched"
fi
