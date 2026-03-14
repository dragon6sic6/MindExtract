#!/bin/bash

# MindExtract — Sign & Notarize
# © 2025 Mindact Solutions AB
#
# Usage: ./sign_and_notarize.sh
# Builds a Universal Binary (arm64 + x86_64) automatically via xcodebuild

set -e

echo "================================================"
echo "  MindExtract Sign & Notarize"
echo "  Mindact Solutions AB"
echo "================================================"
echo ""

# ── Configuration ─────────────────────────────────────────────────────────────
DEVELOPER_ID="Developer ID Application: Mindact Solutions AB (679J7H9973)"
TEAM_ID="679J7H9973"
APPLE_ID="admin@mindact.ai"
# Password stored in macOS Keychain — add with:
# security add-generic-password -a "admin@mindact.ai" -s "MindExtract-Notarization" -w "YOUR_APP_PASSWORD" -U
APP_PASSWORD=$(security find-generic-password -a "$APPLE_ID" -s "MindExtract-Notarization" -w 2>/dev/null)
if [ -z "$APP_PASSWORD" ]; then
    echo "ERROR: App-specific password not found in Keychain."
    echo "Add it with:"
    echo "  security add-generic-password -a \"$APPLE_ID\" -s \"MindExtract-Notarization\" -w \"YOUR_APP_PASSWORD\" -U"
    exit 1
fi
BUNDLE_ID="com.mindact.mindextract"

APP_NAME="MindExtract"
DMG_NAME="MindExtract-1.4.2-Universal"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/dist"
ENTITLEMENTS="$PROJECT_DIR/entitlements.plist"
# ──────────────────────────────────────────────────────────────────────────────

# 1. Build Universal Binary (arm64 + x86_64)
echo "▸ Building Universal Binary (arm64 + x86_64)..."
xcodebuild \
    -project "$PROJECT_DIR/MindExtract.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build | xcpretty 2>/dev/null || xcodebuild \
    -project "$PROJECT_DIR/MindExtract.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build
echo ""

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — could not find $APP_PATH"
    exit 1
fi

# Verify Universal Binary
ARCH_INFO=$(file "$APP_PATH/Contents/MacOS/$APP_NAME")
echo "  Built: $ARCH_INFO"
if echo "$ARCH_INFO" | grep -q "universal binary"; then
    echo "  ✓ Universal Binary confirmed (arm64 + x86_64)"
else
    echo "  ⚠ WARNING: Binary may not be Universal — check ARCHS setting"
fi
echo ""

# 2. Verify entitlements file exists
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: entitlements.plist not found at $ENTITLEMENTS"
    exit 1
fi

# 3. Sign all dylibs and binaries in Resources individually first
echo "▸ Signing bundled binaries and dylibs..."
RESOURCES="$APP_PATH/Contents/Resources"

# Sign all dylibs
find "$RESOURCES" -name "*.dylib" | sort | while read -r lib; do
    echo "  Signing $(basename "$lib")..."
    codesign --force --verify --verbose \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$lib"
done

# Sign all standalone executables (non-.dylib files that are Mach-O)
find "$RESOURCES" -maxdepth 1 -type f ! -name "*.dylib" ! -name "*.icns" ! -name "*.car" | sort | while read -r bin; do
    if file "$bin" | grep -q "Mach-O"; then
        echo "  Signing $(basename "$bin")..."
        codesign --force --verify --verbose \
            --sign "$DEVELOPER_ID" \
            --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --timestamp \
            "$bin"
    fi
done
echo ""

# 4. Deep-sign the .app bundle
echo "▸ Signing .app bundle..."
codesign --deep --force --verify --verbose \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_PATH"
echo ""

# 5. Verify signature
echo "▸ Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH" 2>&1 || true
echo ""

# 6. Create zip for notarization (notarytool requires zip, not dmg at this stage)
echo "▸ Creating zip for notarization..."
mkdir -p "$OUTPUT_DIR"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-notarize.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "  Zip: $ZIP_PATH"
echo ""

# 7. Submit for notarization
echo "▸ Submitting to Apple Notarization service..."
echo "  (This usually takes 1–5 minutes)"
echo ""
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait \
    --verbose
echo ""

# 8. Staple ticket to .app
echo "▸ Stapling notarization ticket to .app..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
echo ""

# 9. Build the DMG (calls existing create_dmg.sh which packages the now-stapled app)
echo "▸ Creating DMG..."
bash "$PROJECT_DIR/create_dmg.sh"
echo ""

# 10. Notarize the DMG too
DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"
if [ -f "$DMG_PATH" ]; then
    echo "▸ Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait \
        --verbose
    echo ""

    echo "▸ Stapling ticket to DMG..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    echo ""
fi

# 11. Final check
echo "▸ Final Gatekeeper check on DMG..."
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" 2>&1 || true

# Cleanup
rm -f "$ZIP_PATH"

echo ""
echo "================================================"
echo "  All done!"
echo "================================================"
echo ""
echo "  Signed & notarized DMG:"
echo "  $DMG_PATH"
echo ""
echo "  Users can install without any macOS warnings."
echo ""
open "$OUTPUT_DIR"

# 12. Update appcast.xml with EdDSA signature and push to GitHub Pages
SPARKLE_TOOLS="/tmp/sparkle290/bin"
APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml"
GITHUB_RELEASES_URL="https://github.com/dragon6sic6/MindExtract/releases/download"

if [ -f "$SPARKLE_TOOLS/sign_update" ] && [ -f "$APPCAST_PATH" ]; then
    echo "▸ Signing DMG for appcast..."
    RAW_SIG=$("$SPARKLE_TOOLS/sign_update" "$DMG_PATH" 2>/dev/null)
    # Extract just the edSignature value
    ED_SIG=$(echo "$RAW_SIG" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"//')
    DMG_FILESIZE=$(stat -f%z "$DMG_PATH")
    VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.2.0")
    BUILD=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "1")
    DOWNLOAD_URL="$GITHUB_RELEASES_URL/v${VERSION}/MindExtract-${VERSION}-Universal.dmg"
    PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

    echo "  Version:   $VERSION ($BUILD)"
    echo "  EdSig:     $ED_SIG"
    echo "  File size: $DMG_FILESIZE"
    echo "  URL:       $DOWNLOAD_URL"

    RELEASE_NOTES_FILE="$PROJECT_DIR/release_notes.html"

    # Build appcast.xml using Python so HTML in release notes is handled safely
    python3 - "$APPCAST_PATH" "$VERSION" "$BUILD" "$ED_SIG" "$DMG_FILESIZE" "$DOWNLOAD_URL" "$PUBDATE" "$RELEASE_NOTES_FILE" << 'PYEOF'
import sys, os

appcast_path, version, build, ed_sig, filesize, url, pubdate, notes_file = sys.argv[1:]

if os.path.exists(notes_file):
    with open(notes_file) as f:
        notes = f.read().strip()
else:
    notes = f"<h2>What's new in {version}</h2>\n<p>Bug fixes and improvements.</p>"

xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MindExtract</title>
    <description>MindExtract — download and transcribe video from anywhere</description>
    <language>en</language>
    <link>https://dragon6sic6.github.io/MindExtract/appcast.xml</link>

    <item>
      <title>Version {version}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure
        url="{url}"
        sparkle:edSignature="{ed_sig}"
        length="{filesize}"
        type="application/octet-stream"
      />
    </item>

  </channel>
</rss>
"""

with open(appcast_path, "w") as f:
    f.write(xml)

print(f"  appcast.xml written with inline release notes")
PYEOF

    echo "  appcast.xml updated ✓"

    # Push docs/ to GitHub
    cd "$PROJECT_DIR"
    git add docs/appcast.xml
    git commit -m "chore: update appcast.xml for v${VERSION}" --allow-empty
    git push origin master
    echo "  appcast.xml pushed to GitHub Pages ✓"
    echo "  Live at: https://dragon6sic6.github.io/MindExtract/appcast.xml"
    cd - > /dev/null
else
    echo "▸ Skipping appcast update (Sparkle tools or appcast.xml not found)"
fi
