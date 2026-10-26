# Changelog

All notable changes to MindExtract. Versions follow [semantic versioning](https://semver.org). Downloads are on the [Releases](https://github.com/dragon6sic6/MindExtract/releases) page.

## 3.0.0 (2026-10-26)

A new app, built around one job: videos and recordings in, text out.

### Added
- MindExtract lives in the notch. Open it by hovering, clicking, or with a global shortcut (⌃⌥Space by default, changeable).
- A copied link is picked up when the notch opens: one click transcribes it or saves the video.
- Drag a video or audio file onto the notch to transcribe it.
- The finished transcript is copied automatically, with title, link and channel on top, ready to paste into an AI chat.
- Copy with or without timestamps. Several speakers are marked turn by turn.
- A short introduction inside the notch on first launch, with a page for people upgrading from 2.x.
- Speech recognition on NVIDIA Parakeet TDT 0.6B v3 for 25 European languages, recognized automatically, and Apple's SpeechAnalyzer for Japanese, Chinese, Korean, Hindi and other languages Apple covers. The 630 MB model downloads once on first launch, pinned and checksum verified.
- Speaker separation with FluidAudio's offline diarizer (pyannote community-1).
- Notifications only when the notch is closed, and only after you allow them.
- Open at login, set up on first launch from Applications.
- Automatic tests on GitHub's macOS 26 runner.

### Changed
- Settings rebuilt in the notch's black and white style, with four tabs and fewer, explained choices.
- Signing in for age restricted or members only videos now borrows the sign in from a browser. YouTube ended the old OAuth login.
- Cancel stops the job for real: late results are ignored and no partial files are saved.
- Download errors are classified from yt-dlp's actual output, so the message says what went wrong.
- The app learns the exact path of a saved video from yt-dlp instead of guessing.
- A file's transcript is saved in the download folder when the file's own folder is read only.
- The app is in English everywhere.
- Bundled yt-dlp updated to 2026.10.21. Bundled tools are fetched by `scripts/setup-tools.sh` instead of living in git.
- Requires macOS 26.

### Removed
- The main window, meeting recording, live captions, dictation, AI summaries and chat, translation, templates, PDF export, app lock and the MCP server.
- Whisper models, KB-Whisper, Klang Pianissimo and the WhisperKit and SpeakerKit dependencies. Their downloaded models are deleted at launch, which often frees more than 1 GB.
- The Swedish translation.
- The `.segments.json` file that used to be written next to every transcript.

Old meeting recordings and transcripts are left on disk untouched.

## 2.x (June 2026)

The meetings era, from 2.0.0 to 2.8.0.

- **2.8.0** Today as a command center, smarter meeting capture, Recipes, MCP server.
- **2.7.0** Structured commitments and meeting prep.
- **2.6.0** Today, commitments, People and Topics.
- **2.5.0 to 2.5.2** Meeting Brief, marked moments, recap email, auto record, calendar nudges.
- **2.4.0** Transcript editor, app lock, branded PDFs, batch transcription.
- **2.3.0 and 2.3.1** Calendar detection, speaker names, live captions, search and ask across transcripts.
- **2.2.0** Meeting recording.
- **2.1.0 to 2.1.6** AI summaries and transcript chat with several providers, quality picker for downloads.
- **2.0.0** Redesign with Apple's speech engine and a media first flow.

## 1.x (February to March 2026)

- **1.5.x** Speaker diarization, WhisperKit model downloads, Sparkle update fixes.
- **1.4.x** Move to WhisperKit.
- **1.2.0 to 1.3.x** Sidebar layout, onboarding, download queue, separate download and transcribe flows.
- **1.0.0** First release: download from 1000+ sites and transcribe locally.
