#!/bin/bash

# Video Downloader DMG Creator
# © 2025 Mindact

set -e

echo "================================================"
echo "  Video Downloader DMG Creator"
echo "  by Mindact"
echo "================================================"
echo ""

# Configuration
APP_NAME="Video Downloader"
DMG_NAME="VideoDownloader-1.0.0-Universal"
VOLUME_NAME="Video Downloader"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$PROJECT_DIR/dmg_temp"
OUTPUT_DIR="$PROJECT_DIR/dist"

# Find the built app
echo "Looking for built app..."

# Check common build locations
APP_PATH=""
POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/VideoDownloader-*/Build/Products/Release/VideoDownloader.app"
    "$BUILD_DIR/Build/Products/Release/VideoDownloader.app"
    "$PROJECT_DIR/build/Release/VideoDownloader.app"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -d "$path" ]; then
            APP_PATH="$path"
            break 2
        fi
    done
done

if [ -z "$APP_PATH" ]; then
    echo ""
    echo "ERROR: Could not find VideoDownloader.app"
    echo ""
    echo "Please build the app first in Xcode:"
    echo "  1. Open VideoDownloader.xcodeproj in Xcode"
    echo "  2. Select 'Any Mac (Apple Silicon, Intel)' as destination"
    echo "  3. Select Product > Build For > Running"
    echo "  4. Run this script again"
    echo ""
    exit 1
fi

echo "Found app at: $APP_PATH"

# Verify yt-dlp is bundled
if [ ! -f "$APP_PATH/Contents/Resources/yt-dlp" ]; then
    echo ""
    echo "WARNING: yt-dlp not found in app bundle!"
    echo "The app may not work without it."
    echo ""
fi

# Check architecture
echo ""
echo "Checking app architecture..."
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/VideoDownloader" 2>/dev/null || echo "unknown")
echo "App architectures: $ARCHS"

if [ -f "$APP_PATH/Contents/Resources/yt-dlp" ]; then
    YTDLP_ARCHS=$(lipo -archs "$APP_PATH/Contents/Resources/yt-dlp" 2>/dev/null || echo "unknown")
    echo "yt-dlp architectures: $YTDLP_ARCHS"
fi

# Clean up old files
echo ""
echo "Preparing build directories..."
rm -rf "$DMG_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$DMG_DIR"
mkdir -p "$OUTPUT_DIR"

# Copy app to DMG directory
echo "Copying app..."
cp -R "$APP_PATH" "$DMG_DIR/"

# Create Applications symlink
ln -s /Applications "$DMG_DIR/Applications"

# Create the DMG
echo ""
echo "Creating DMG installer..."
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$OUTPUT_DIR/$DMG_NAME.dmg"

# Clean up
rm -rf "$DMG_DIR"

# Get DMG size
DMG_SIZE=$(ls -lh "$OUTPUT_DIR/$DMG_NAME.dmg" | awk '{print $5}')

echo ""
echo "================================================"
echo "  DMG created successfully!"
echo "================================================"
echo ""
echo "Location: $OUTPUT_DIR/$DMG_NAME.dmg"
echo "Size: $DMG_SIZE"
echo ""
echo "The app is FULLY SELF-CONTAINED."
echo "Your friends just need to:"
echo "  1. Double-click the DMG"
echo "  2. Drag to Applications"
echo "  3. Run the app!"
echo ""

# Open the output directory
open "$OUTPUT_DIR"
