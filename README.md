# MindExtract

A native macOS app for downloading videos from 1000+ platforms and transcribing audio locally using OpenAI Whisper — no cloud processing, fully private.

Built with Swift and SwiftUI. No third-party Swift dependencies.

## Features

- **Video downloading** from YouTube, X/Twitter, Instagram, TikTok, LinkedIn, Facebook, Vimeo, and 1000+ more platforms (powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp))
- **Local audio transcription** using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — runs entirely on your Mac, nothing leaves your machine
- **Multiple formats** — choose video quality or download audio only as MP3
- **Configurable resolution preset** — set your preferred quality (720p, 1080p, 1440p, 4K) as a one-click shortcut
- **Download queue** — add multiple videos, then download them all at once with a single click
- **Separate Download & Transcribe workflows** — paste a URL in Transcribe to get a transcript directly, without saving the video
- **Subtitle download** with language selection
- **Transcription output** as plain text (`.txt`) or SRT subtitles (`.srt`)
- **Language selection** — auto-detect or pick from 15+ languages
- **Batch downloads** — scan playlists, channels, or profile pages and queue multiple downloads
- **Parallel downloads** — up to 4 concurrent downloads
- **YouTube authentication** — sign in via OAuth or browser cookies for age-restricted/private content
- **Drag and drop** — drop URLs or video files directly into the app
- **Download & transcription history** — track all your past activity
- **Desktop notifications** with optional sound alerts
- **Light / Dark / System** appearance modes
- **Fully self-contained** — all tools are bundled, no Homebrew or external installs needed

## Installation (Pre-built DMG)

1. Download the latest `.dmg` from [Releases](../../releases)
2. Open the `.dmg` and drag **MindExtract** to your **Applications** folder
3. Launch MindExtract from Applications

> The app is **signed and notarized by Apple** — no security warnings, no Terminal commands needed.

### Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac

## Uninstallation

To fully remove MindExtract and all associated data:

```bash
curl -fsSL https://raw.githubusercontent.com/dragon6sic6/MindExtract/master/uninstall.sh | bash
```

Or if you have the repo cloned:

```bash
./uninstall.sh
```

This removes the app, Whisper models, download history, preferences, and all caches — leaving your system completely clean.

## Building from Source

### Prerequisites

- Xcode 15+ with macOS SDK
- macOS 13.0+

### Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/dragon6sic6/MindExtract.git
   cd MindExtract
   ```

2. Download the required binaries:
   ```bash
   ./setup_binaries.sh
   ```
   This downloads `yt-dlp`, `ffmpeg`, and `whisper-cpp` (+ its libraries) into `MindExtract/Resources/`. These are too large to include in git.

3. Open in Xcode:
   ```bash
   open MindExtract.xcodeproj
   ```

4. Select **"Any Mac (Apple Silicon, Intel)"** as the build destination

5. Build: **Product > Build** (Cmd+B)

6. (Optional) Sign, notarize, and create a distributable DMG:
   ```bash
   ./sign_and_notarize.sh
   ```
   Requires a Developer ID certificate and Apple app-specific password stored in Keychain.

## How It Works

### Video Downloading

Uses [yt-dlp](https://github.com/yt-dlp/yt-dlp) to fetch video metadata and download media. Supports format selection, subtitle embedding, and authentication via YouTube OAuth or browser cookie extraction (Safari, Chrome, Firefox, Brave, Edge).

### Local Transcription

Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (a C/C++ port of OpenAI's Whisper model) for fully offline speech-to-text. The pipeline:

1. **FFmpeg** extracts audio from the video file (16kHz, mono, 16-bit PCM WAV)
2. **whisper-cpp** runs the selected model on the audio
3. Output is saved as `.txt` or `.srt` alongside the source file

Whisper models are downloaded on-demand from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) and stored locally. Hardware acceleration via Apple Metal GPU is used when available.

#### Available Whisper Models

| Model  | Size   | Speed    | Accuracy |
|--------|--------|----------|----------|
| Tiny   | 75 MB  | Fastest  | Basic    |
| Base   | 142 MB | Fast     | Good     |
| Small  | 466 MB | Moderate | Better   |
| Medium | 1.5 GB | Slowest  | Best     |

### Audio Processing

Uses [FFmpeg](https://ffmpeg.org/) for audio extraction and format conversion. FFmpeg is bundled inside the app — no separate installation required.

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 5.9+ |
| UI Framework | SwiftUI |
| Navigation | NavigationSplitView (sidebar layout) |
| Reactive state | Combine (`@Published`, `ObservableObject`) |
| Video downloading | [yt-dlp](https://github.com/yt-dlp/yt-dlp) (bundled binary) |
| Audio extraction | [FFmpeg](https://ffmpeg.org/) (bundled binary) |
| Transcription | [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (bundled binary + GGML libs) |
| GPU acceleration | Apple Metal via GGML |
| Persistence | UserDefaults (JSON-encoded history) |
| Notifications | UserNotifications framework |
| Audio/Video info | AVFoundation |
| Platform | macOS 13.0+ (Ventura) |

## Project Structure

```
MindExtract/
├── MindExtractApp.swift               # App entry point, onboarding overlay
├── ContentView.swift                  # Main UI — sidebar + Download / Transcribe / History / Settings
├── Models.swift                       # Data models, enums, AppSettings, history managers
├── YTDLPWrapper.swift                 # yt-dlp integration — downloads, auth, page scanning, queue
├── TranscriptionManager.swift         # Whisper/FFmpeg — model management, transcription pipeline
├── SettingsView.swift                 # Settings UI
├── TranscriptionSettingsView.swift    # Whisper model management UI
├── TranscriptionResultView.swift      # Transcription output viewer with live progress
├── HistoryView.swift                  # Download & transcription history UI
├── OnboardingView.swift               # First-launch Whisper model setup wizard
├── AboutView.swift                    # About dialog
├── MindExtract.entitlements           # App permissions
├── Info.plist                         # App metadata
├── Assets.xcassets/                   # App icons and colors
└── Resources/                         # Bundled binaries (not in git — run setup_binaries.sh)
    ├── yt-dlp                         # Video downloader
    ├── ffmpeg                         # Audio extraction
    ├── whisper                        # Transcription engine
    └── lib*.dylib                     # GGML/Whisper shared libraries
```

## Data Storage

All data stays on your machine. No cloud, no accounts, no telemetry.

| Data | Location | Limit |
|------|----------|-------|
| Download history | UserDefaults | 100 items |
| Transcription history | UserDefaults | 50 items |
| App settings | UserDefaults | — |
| Downloaded media | Your chosen folder (default: ~/Downloads) | — |
| Transcription output | Same folder as source media | — |
| Whisper models | ~/Library/Application Support/com.mindact.mindextract/WhisperModels/ | — |

## Changelog

### v1.1.0
- **Sidebar navigation** — Download, Transcribe, History, and Settings each get their own section
- **Onboarding wizard** — first-launch guide walks through downloading a Whisper model
- **Download queue** — queue multiple videos, then download them all at once; adding a video auto-resets the input for the next one
- **Configurable resolution preset** — choose your preferred quality (720p / 1080p / 1440p / 4K) in Settings; the quick-format button updates automatically
- **Separate Transcribe workflow** — paste a URL in the Transcribe section to get a transcript without saving the video
- **Animated transcription indicator** — waveform animation plays while waiting for the first transcript words
- **Neutral UI theme** — removed pink accent color in favor of a clean grey/white system palette

### v1.0.0
- Initial release

## License

MIT License — see [LICENSE](LICENSE) for details.

© 2025 [Mindact Solutions AB](https://mindact.ai)
