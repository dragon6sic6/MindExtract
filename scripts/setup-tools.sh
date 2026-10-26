#!/bin/bash
#
# Puts the command line tools MindExtract bundles into MindExtract/Resources/:
#   ytdlp/     yt-dlp, official universal onedir build, checksum verified
#   ffmpeg     universal static build (arm64 + x86_64), built from source
#   ffprobe    built alongside ffmpeg
#
# They aren't kept in git. Run this once after cloning, and again to update.
#
#   scripts/setup-tools.sh                 # both
#   scripts/setup-tools.sh ytdlp           # only yt-dlp
#   scripts/setup-tools.sh ffmpeg          # only ffmpeg and ffprobe
#
# Override versions with YTDLP_VERSION=2026.10.21 or FFMPEG_VERSION=7.1.2.

set -euo pipefail

YTDLP_VERSION="${YTDLP_VERSION:-2026.10.21}"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.2}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT/MindExtract/Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

what="${1:-all}"

setup_ytdlp() {
    echo "==> yt-dlp $YTDLP_VERSION"
    local base="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
    curl -fsSL -o "$WORK/yt-dlp_macos.zip" "$base/yt-dlp_macos.zip"
    curl -fsSL -o "$WORK/SHA2-256SUMS" "$base/SHA2-256SUMS"

    local expected actual
    expected="$(awk '$2 == "yt-dlp_macos.zip" { print $1 }' "$WORK/SHA2-256SUMS")"
    actual="$(shasum -a 256 "$WORK/yt-dlp_macos.zip" | awk '{ print $1 }')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "Checksum mismatch for yt-dlp_macos.zip (expected $expected, got $actual)" >&2
        exit 1
    fi
    echo "    checksum ok"

    mkdir "$WORK/ytdlp"
    ditto -x -k "$WORK/yt-dlp_macos.zip" "$WORK/ytdlp"

    # The zip flattens Python.framework's symlinks into copies, and codesign
    # then refuses the framework ("bundle format is ambiguous"). Put them back.
    local fw="$WORK/ytdlp/_internal/Python.framework"
    if [ -d "$fw/Versions" ]; then
        local version
        version="$(ls "$fw/Versions" | grep -v '^Current$' | head -1)"
        rm -rf "$fw/Versions/Current" "$fw/Python" "$fw/Resources"
        ln -s "$version" "$fw/Versions/Current"
        ln -s Versions/Current/Python "$fw/Python"
        ln -s Versions/Current/Resources "$fw/Resources"
    fi

    rm -rf "$RESOURCES/ytdlp"
    ditto "$WORK/ytdlp" "$RESOURCES/ytdlp"
    xattr -cr "$RESOURCES/ytdlp"
    echo "    installed: $("$RESOURCES/ytdlp/yt-dlp_macos" --version)"
}

setup_ffmpeg() {
    echo "==> ffmpeg $FFMPEG_VERSION (building both architectures, this takes a while)"
    local tarball="ffmpeg-$FFMPEG_VERSION.tar.xz"
    curl -fsSL -o "$WORK/$tarball" "https://ffmpeg.org/releases/$tarball"
    curl -fsSL -o "$WORK/$tarball.asc" "https://ffmpeg.org/releases/$tarball.asc"
    if command -v gpg > /dev/null; then
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys B4322F04D67658D8 > /dev/null 2>&1 || true
        gpg --verify "$WORK/$tarball.asc" "$WORK/$tarball" 2> /dev/null \
            || { echo "FFmpeg source signature didn't verify" >&2; exit 1; }
        echo "    signature ok"
    else
        echo "    (gpg not installed, skipping the source signature check)"
    fi
    (cd "$WORK" && FFMPEG_TARBALL="$tarball" bash "$ROOT/scripts/build-ffmpeg.sh")
    install -m 755 "$WORK/universal/ffmpeg" "$RESOURCES/ffmpeg"
    install -m 755 "$WORK/universal/ffprobe" "$RESOURCES/ffprobe"
    lipo -info "$RESOURCES/ffmpeg"
}

case "$what" in
    all)    setup_ytdlp; setup_ffmpeg ;;
    ytdlp)  setup_ytdlp ;;
    ffmpeg) setup_ffmpeg ;;
    *) echo "Usage: $0 [all|ytdlp|ffmpeg]" >&2; exit 2 ;;
esac

echo "Done. Tools are in $RESOURCES"
