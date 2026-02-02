#!/bin/bash

# Script to help with bundling whisper and ffmpeg binaries for MindExtract
# This script provides guidance - you may need to manually download static builds

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/VideoDownloader/Resources"

echo "=============================================="
echo "MindExtract - Binary Bundling Helper"
echo "=============================================="

# Check if Resources directory exists
if [ ! -d "$RESOURCES_DIR" ]; then
    echo "Error: Resources directory not found at $RESOURCES_DIR"
    exit 1
fi

echo ""
echo "Current Resources folder contents:"
ls -la "$RESOURCES_DIR"

echo ""
echo "=============================================="
echo "IMPORTANT: Static Builds Required"
echo "=============================================="
echo ""
echo "Homebrew binaries are dynamically linked and won't work when bundled."
echo "You need STATIC builds for bundling."
echo ""

# Check for ffmpeg
echo "=== FFmpeg ==="
if [ -f "$RESOURCES_DIR/ffmpeg" ]; then
    SIZE=$(ls -lh "$RESOURCES_DIR/ffmpeg" | awk '{print $5}')
    echo "Found ffmpeg in Resources ($SIZE)"
    # Check if it's likely a static build (> 10MB)
    SIZE_BYTES=$(stat -f%z "$RESOURCES_DIR/ffmpeg" 2>/dev/null || stat -c%s "$RESOURCES_DIR/ffmpeg" 2>/dev/null)
    if [ "$SIZE_BYTES" -lt 10000000 ]; then
        echo "WARNING: This ffmpeg appears to be a dynamic build (< 10MB)."
        echo "         It may not work when the app is distributed."
    fi
else
    echo "Not found in Resources folder."
    echo ""
    echo "To add ffmpeg:"
    echo "1. Download static build from: https://evermeet.cx/ffmpeg/"
    echo "2. Extract the ffmpeg binary"
    echo "3. Copy to: $RESOURCES_DIR/ffmpeg"
    echo "4. Run: chmod +x $RESOURCES_DIR/ffmpeg"
fi

echo ""
echo "=== Whisper ==="
if [ -f "$RESOURCES_DIR/whisper" ]; then
    SIZE=$(ls -lh "$RESOURCES_DIR/whisper" | awk '{print $5}')
    echo "Found whisper in Resources ($SIZE)"
else
    echo "Not found in Resources folder."
    echo ""
    echo "To add whisper:"
    echo "1. Download from: https://github.com/ggerganov/whisper.cpp/releases"
    echo "2. Extract and find the 'main' binary"
    echo "3. Rename to 'whisper' and copy to: $RESOURCES_DIR/"
    echo "4. Run: chmod +x $RESOURCES_DIR/whisper"
fi

echo ""
echo "=============================================="
echo "Fallback: System Binaries"
echo "=============================================="

# Check system paths
echo ""
echo "System binaries (will be used as fallback if bundled binaries not found):"
echo ""

FFMPEG_SYS=$(which ffmpeg 2>/dev/null)
if [ -n "$FFMPEG_SYS" ]; then
    echo "ffmpeg: $FFMPEG_SYS (installed)"
else
    echo "ffmpeg: NOT FOUND (install with: brew install ffmpeg)"
fi

WHISPER_SYS=$(which whisper 2>/dev/null)
if [ -n "$WHISPER_SYS" ]; then
    echo "whisper: $WHISPER_SYS (installed)"
else
    echo "whisper: NOT FOUND (install with: brew install whisper-cpp)"
fi

echo ""
echo "=============================================="
echo "After Adding Binaries"
echo "=============================================="
echo ""
echo "1. Open Xcode project"
echo "2. Right-click Resources folder in Project Navigator"
echo "3. Select 'Add Files to VideoDownloader...'"
echo "4. Select the new binaries (whisper, ffmpeg)"
echo "5. Ensure 'Add to targets: VideoDownloader' is checked"
echo "6. Build and test"
echo ""
