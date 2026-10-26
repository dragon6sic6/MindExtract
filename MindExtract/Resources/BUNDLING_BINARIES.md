# Bundled tools

MindExtract ships two command line tools in `Resources/`. They aren't kept in
git; `scripts/setup-tools.sh` puts them here. Transcription itself needs
neither: audio is converted with AVFoundation (`AudioConverter.swift`), and
ffmpeg is only the fallback for formats Apple can't open.

```bash
scripts/setup-tools.sh            # both
scripts/setup-tools.sh ytdlp      # only yt-dlp
scripts/setup-tools.sh ffmpeg     # only ffmpeg and ffprobe
```

## yt-dlp (downloads)

The official universal onedir build (`yt-dlp_macos.zip`) from
[yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases), checked against
the release's `SHA2-256SUMS`, unpacked into `Resources/ytdlp/`. The zip stores
`_internal/Python.framework` with its symlinks flattened into copies, which
codesign refuses ("bundle format is ambiguous"), so the script restores them.

Update it often. Sites like YouTube change, and old versions start failing
with HTTP 403. Bump `YTDLP_VERSION` in the script.

The app passes `--ffmpeg-location` so yt-dlp uses the bundled ffmpeg
(`BundledTools` in `AudioConverter.swift`), and `--no-update`.

## ffmpeg and ffprobe (merging video and audio)

Universal (Apple Silicon and Intel), static, LGPL, built from the official
FFmpeg source by `scripts/build-ffmpeg.sh` (the source signature is checked
when gpg is installed). It only links frameworks and libraries that ship with
macOS, so it runs on every Mac without Rosetta or Homebrew.

Check: `file Resources/ffmpeg` must list both `x86_64` and `arm64`.

Don't bundle an Intel-only or Homebrew (dynamically linked) ffmpeg. It fails
with "Bad CPU type" or missing libraries on other Macs.

All of it is signed by `scripts/release.sh` during release.
