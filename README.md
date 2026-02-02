# MindExtract

A macOS app for downloading videos from 1000+ platforms and transcribing audio locally using Whisper — no cloud processing, fully private.

## Installation

1. Open the `.dmg` file
2. Drag **MindExtract** to your **Applications** folder
3. Open Terminal and run:
   ```
   xattr -cr /Applications/MindExtract.app
   ```
   This removes the macOS Gatekeeper quarantine flag. It's required because the app is not signed with an Apple Developer ID. Without this step, macOS will refuse to open the app.
4. Open **MindExtract** from Applications

## Features

- **Download videos** from YouTube, X/Twitter, Instagram, TikTok, LinkedIn, Facebook, Vimeo, and more
- **Transcribe audio** locally using Whisper — from a URL or a local file
- **Multiple formats** — choose video quality (1080p, 720p, 480p) or download audio only as MP3
- **Subtitle download** with language selection
- **Transcription output** as plain text (.txt) or SRT subtitles (.srt)
- **Language selection** — auto-detect or pick from 15+ languages
- **Batch downloads** — scan playlists, channels, or pages and queue multiple downloads
- **Fully self-contained** — yt-dlp, Whisper, and FFmpeg are bundled with the app

## First-Time Use

Transcription requires a Whisper model. Go to **Settings** and download one:

| Model  | Size   | Notes                              |
|--------|--------|------------------------------------|
| Tiny   | 75 MB  | Fastest, lower accuracy            |
| Base   | 142 MB | Good balance of speed and accuracy  |
| Small  | 466 MB | Better accuracy                    |
| Medium | 1.5 GB | Best accuracy, slowest             |

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel
