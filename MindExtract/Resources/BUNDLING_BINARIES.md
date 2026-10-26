# Bundled tools

MindExtract ships two external tools in `Resources/`. Transcription itself needs
neither: audio is converted with AVFoundation (`AudioConverter.swift`).

## ffmpeg + ffprobe (downloads: merging video and audio, audio extraction)

Universal (Apple Silicon + Intel), static, LGPL build made from the official
FFmpeg source. It only links frameworks and libraries that ship with macOS, so it
runs on every Mac without Rosetta or Homebrew.

Rebuild:

```bash
mkdir -p /tmp/ffbuild && cd /tmp/ffbuild
curl -LO https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz
curl -LO https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz.asc
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys B4322F04D67658D8   # FFmpeg release key
gpg --verify ffmpeg-7.1.2.tar.xz.asc ffmpeg-7.1.2.tar.xz
cp /path/to/repo/scripts/build-ffmpeg.sh . && ./build-ffmpeg.sh
cp universal/ffmpeg universal/ffprobe /path/to/repo/MindExtract/Resources/
```

Check: `file Resources/ffmpeg` must list both `x86_64` and `arm64`.

Don't bundle an Intel-only or Homebrew (dynamically linked) ffmpeg — it fails with
"Bad CPU type" or missing libraries on other Macs.

## yt-dlp (downloads)

The official `yt-dlp_macos.zip` (universal onedir build) from
https://github.com/yt-dlp/yt-dlp/releases, unpacked into `Resources/ytdlp/`.
Verify it against `SHA2-256SUMS` from the same release.

The zip stores `_internal/Python.framework` with its symlinks flattened into
copies, and codesign then refuses it ("bundle format is ambiguous"). After
unpacking, turn them back into symlinks:

```bash
cd MindExtract/Resources/ytdlp/_internal/Python.framework
rm -rf Versions/Current Python Resources
ln -s 3.14 Versions/Current            # the version folder that's there
ln -s Versions/Current/Python Python
ln -s Versions/Current/Resources Resources
``` Update it regularly —
sites like YouTube change often and old versions start failing (HTTP 403).

The app passes `--ffmpeg-location` so yt-dlp always uses a working ffmpeg
(`BundledTools` in `AudioConverter.swift`), and `--no-update`.

Both are signed by `sign_and_notarize.sh` during release.
