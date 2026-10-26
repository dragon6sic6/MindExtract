# MindExtract

Download and transcribe video from anywhere, right from your Mac's notch.

Paste a link (or drag a file onto the notch), and MindExtract saves the video or turns the speech into text. The transcript lands on your clipboard, ready to paste into Claude, ChatGPT or anywhere else. Everything runs on your Mac. Nothing is uploaded.

## What it does

- **Lives in the notch.** Hover or click the notch, or press ⌃⌥Space (changeable) from any app. No Dock icon, no windows.
- **Link in, text out.** YouTube and over a thousand other sites, through [yt-dlp](https://github.com/yt-dlp/yt-dlp). A copied link is picked up automatically: one click transcribes it.
- **Files too.** Drag any video or audio file onto the notch.
- **Ready for AI.** The finished transcript is copied with its title, link and channel on top. With or without timestamps; speakers are told apart.
- **On-device speech recognition.** Apple's SpeechAnalyzer, downloadable Whisper models (WhisperKit), and Pianissimo for Swedish. Speaker separation with SpeakerKit.
- **Save the video** in the quality you choose, or only the audio.

## Install

1. Download the latest `.dmg` from [Releases](../../releases).
2. Drag **MindExtract** to **Applications** and open it.
3. The notch introduces itself. That's it.

Signed and notarized by Apple. Updates arrive through Sparkle.

### Requirements

- macOS 26 or later
- Apple Silicon or Intel Mac
- Internet only for fetching videos and speech models

## Build from source

1. Clone the repository and open `MindExtract.xcodeproj` in Xcode 26.
2. Build the **MindExtract** scheme.
3. Bundled tools live in `MindExtract/Resources/` (yt-dlp onedir build, universal ffmpeg). See `MindExtract/Resources/BUNDLING_BINARIES.md` for how to update them.

To make a signed, notarized DMG:

```bash
./sign_and_notarize.sh
```

It needs a Developer ID certificate and an app-specific password in the Keychain. The script commits the updated `docs/appcast.xml` but does not push it: upload the DMG to the GitHub release first, then push.

## Where things are stored

| What | Where |
|------|-------|
| Saved videos and link transcripts | Your chosen folder (default `~/Downloads`) |
| Transcript of a file | Next to the file (or the save folder if that one is read-only) |
| Speech models and history | `~/Library/Application Support/com.mindact.mindextract/` |
| Settings | UserDefaults |

No accounts, no telemetry.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, speech models, history, preferences and caches.

## License

MIT. See [LICENSE](LICENSE).

Pianissimo by Klang AI AB, CC BY 4.0.

© 2026 [Mindact Solutions AB](https://mindact.ai)
