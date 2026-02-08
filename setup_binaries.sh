#!/bin/bash

# MindExtract - Binary Setup Script
# Downloads required binaries for building from source.
# Run this after cloning the repo: ./setup_binaries.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/VideoDownloader/Resources"

echo "=============================================="
echo "  MindExtract - Binary Setup"
echo "=============================================="
echo ""

mkdir -p "$RESOURCES_DIR"

# ── yt-dlp ──────────────────────────────────────────

echo "==> Downloading yt-dlp..."
if [ -f "$RESOURCES_DIR/yt-dlp" ]; then
    echo "    Already exists, skipping. Delete to re-download."
else
    curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" \
        -o "$RESOURCES_DIR/yt-dlp"
    chmod +x "$RESOURCES_DIR/yt-dlp"
    echo "    Done."
fi

# ── FFmpeg ──────────────────────────────────────────

echo ""
echo "==> Downloading FFmpeg (static build)..."
if [ -f "$RESOURCES_DIR/ffmpeg" ]; then
    echo "    Already exists, skipping. Delete to re-download."
else
    # evermeet.cx provides static macOS builds of FFmpeg
    FFMPEG_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
    FFMPEG_TMP="$RESOURCES_DIR/ffmpeg_tmp.zip"
    curl -L "$FFMPEG_URL" -o "$FFMPEG_TMP"
    unzip -o "$FFMPEG_TMP" -d "$RESOURCES_DIR/"
    rm -f "$FFMPEG_TMP"
    chmod +x "$RESOURCES_DIR/ffmpeg"
    echo "    Done."
fi

# ── Whisper.cpp ─────────────────────────────────────

echo ""
echo "==> Downloading whisper.cpp..."
if [ -f "$RESOURCES_DIR/whisper" ]; then
    echo "    Already exists, skipping. Delete to re-download."
else
    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        WHISPER_ASSET="whisper"
        echo "    Detected Apple Silicon (arm64)"
    else
        WHISPER_ASSET="whisper"
        echo "    Detected Intel (x86_64)"
    fi

    # Get latest release tag
    LATEST_TAG=$(curl -s "https://api.github.com/repos/ggerganov/whisper.cpp/releases/latest" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    echo "    Latest release: $LATEST_TAG"

    # Try to download pre-built release
    WHISPER_URL="https://github.com/ggerganov/whisper.cpp/releases/download/${LATEST_TAG}/whisper-${LATEST_TAG}-bin-macos-${ARCH}.zip"
    WHISPER_TMP="$RESOURCES_DIR/whisper_tmp.zip"

    echo "    Downloading from: $WHISPER_URL"
    HTTP_CODE=$(curl -sL -w "%{http_code}" "$WHISPER_URL" -o "$WHISPER_TMP")

    if [ "$HTTP_CODE" = "200" ] && [ -f "$WHISPER_TMP" ]; then
        # Extract
        WHISPER_EXTRACT="$RESOURCES_DIR/whisper_extract"
        mkdir -p "$WHISPER_EXTRACT"
        unzip -o "$WHISPER_TMP" -d "$WHISPER_EXTRACT"

        # Find and copy the main binary (could be named 'main' or 'whisper-cli' or 'whisper')
        WHISPER_BIN=$(find "$WHISPER_EXTRACT" -type f \( -name "main" -o -name "whisper-cli" -o -name "whisper" \) | head -1)
        if [ -n "$WHISPER_BIN" ]; then
            cp "$WHISPER_BIN" "$RESOURCES_DIR/whisper"
            chmod +x "$RESOURCES_DIR/whisper"
        fi

        # Copy dylibs
        find "$WHISPER_EXTRACT" -name "*.dylib" -exec cp {} "$RESOURCES_DIR/" \;

        # Clean up
        rm -rf "$WHISPER_EXTRACT" "$WHISPER_TMP"
        echo "    Done."
    else
        rm -f "$WHISPER_TMP"
        echo ""
        echo "    Could not download pre-built whisper release."
        echo "    You can build it manually:"
        echo "      git clone https://github.com/ggerganov/whisper.cpp"
        echo "      cd whisper.cpp && make"
        echo "      cp main $RESOURCES_DIR/whisper"
        echo "      cp libwhisper*.dylib libggml*.dylib $RESOURCES_DIR/"
    fi
fi

# ── Summary ─────────────────────────────────────────

echo ""
echo "=============================================="
echo "  Setup Summary"
echo "=============================================="
echo ""

check_binary() {
    if [ -f "$RESOURCES_DIR/$1" ]; then
        SIZE=$(ls -lh "$RESOURCES_DIR/$1" | awk '{print $5}')
        echo "  [OK]  $1 ($SIZE)"
    else
        echo "  [--]  $1 (MISSING)"
    fi
}

check_binary "yt-dlp"
check_binary "ffmpeg"
check_binary "whisper"
check_binary "libwhisper.1.dylib"
check_binary "libggml.0.dylib"
check_binary "libggml-cpu.0.dylib"
check_binary "libggml-blas.0.dylib"
check_binary "libggml-metal.0.dylib"
check_binary "libggml-base.0.dylib"

echo ""
echo "You can now open VideoDownloader.xcodeproj in Xcode and build."
echo ""
