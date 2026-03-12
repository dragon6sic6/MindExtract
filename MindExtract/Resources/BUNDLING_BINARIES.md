# Bundling Binaries for Transcription

This document explains how to add the required binaries for the transcription feature.

## Required Binaries

1. **whisper** (~5 MB) - The whisper.cpp main binary for transcription
2. **ffmpeg** (~80 MB static build) - For extracting audio from video files

## Important: Static vs Dynamic Builds

Homebrew installs dynamically-linked binaries that depend on shared libraries. These will **NOT** work when bundled in the app because the libraries won't be available.

You need **static builds** that include all dependencies in a single binary.

## Recommended: Download Static Builds

### FFmpeg (Static Build)

1. Go to: https://evermeet.cx/ffmpeg/
2. Download the latest `ffmpeg-X.X.X.zip` (about 80 MB)
3. Extract and copy the `ffmpeg` binary to this Resources folder
4. Make it executable: `chmod +x ffmpeg`

### Whisper.cpp

1. Go to: https://github.com/ggerganov/whisper.cpp/releases
2. Download the macOS release (e.g., `whisper-1.x.x-bin-macos-arm64.zip`)
3. Extract and find the `main` binary (this is the transcription tool)
4. Rename it to `whisper` and copy to this Resources folder
5. Make it executable: `chmod +x whisper`

**Alternative: Build from source**
```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
make
cp main /path/to/MindExtract/Resources/whisper
```

## Fallback Behavior

If binaries are not bundled, the app will try to use system-installed binaries from:
- `/opt/homebrew/bin/` (Apple Silicon Homebrew)
- `/usr/local/bin/` (Intel Homebrew)
- `/usr/bin/`

This means users with Homebrew installed will still be able to use transcription even without bundled binaries.

## After Adding Binaries

1. In Xcode, right-click on the Resources folder in the Project Navigator
2. Select "Add Files to 'MindExtract'..."
3. Select the `whisper` and `ffmpeg` binaries
4. Make sure "Copy items if needed" is **unchecked** (files are already in place)
5. Ensure "Add to targets: MindExtract" is checked
6. Click "Add"

## Verification

After building, go to **Settings > Transcription > Manage Models** in the app.
You should see green checkmarks next to "Whisper" and "FFmpeg" indicating they're available.

## File Sizes (Approximate)

| Binary | Dynamic (Homebrew) | Static (Recommended) |
|--------|-------------------|---------------------|
| ffmpeg | ~400 KB | ~80 MB |
| whisper | ~500 KB | ~5 MB |

The static builds are larger because they include all dependencies.
