#!/bin/bash

# MindExtract DMG Creator
# © 2025 Mindact

set -e

echo "================================================"
echo "  MindExtract DMG Creator"
echo "  by Mindact"
echo "================================================"
echo ""

# Configuration
APP_NAME="MindExtract"
DMG_NAME="MindExtract-1.5.11-Universal"
VOLUME_NAME="MindExtract"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$PROJECT_DIR/dmg_temp"
OUTPUT_DIR="$PROJECT_DIR/dist"

# Find the built app
echo "Looking for built app..."

# Check common build locations
APP_PATH=""
POSSIBLE_PATHS=(
    "$BUILD_DIR/Build/Products/Release/MindExtract.app"
    "$PROJECT_DIR/build/Release/MindExtract.app"
    "$HOME/Library/Developer/Xcode/DerivedData/MindExtract-*/Build/Products/Release/MindExtract.app"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    while IFS= read -r -d '' path; do
        if [ -d "$path" ]; then
            APP_PATH="$path"
            break 2
        fi
    done < <(compgen -G "$path_pattern" | tr '\n' '\0' 2>/dev/null)
    # Fallback: try the pattern directly (no glob)
    if [ -z "$APP_PATH" ] && [ -d "$path_pattern" ]; then
        APP_PATH="$path_pattern"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    echo ""
    echo "ERROR: Could not find MindExtract.app"
    echo ""
    echo "Please build the app first in Xcode:"
    echo "  1. Open MindExtract.xcodeproj in Xcode"
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
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/MindExtract" 2>/dev/null || echo "unknown")
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

# Copy README
if [ -f "$PROJECT_DIR/README.txt" ]; then
    cp "$PROJECT_DIR/README.txt" "$DMG_DIR/"
    echo "Included README.txt"
elif [ -f "$PROJECT_DIR/README.md" ]; then
    cp "$PROJECT_DIR/README.md" "$DMG_DIR/"
    echo "Included README.md"
fi

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
