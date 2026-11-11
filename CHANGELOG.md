# Changelog

All notable changes to MindExtract. Versions follow [semantic versioning](https://semver.org). Downloads are on the [Releases](https://github.com/dragon6sic6/MindExtract/releases) page.

## 3.0.2 (2026-11-11)

### Added
- Save is one split button: it saves the size it names, and its arrow lists the sizes the video comes in (up to 8K), plus Audio only. Sizes only offered in a format the Mac can't play are marked as converted after saving, and can instead be saved as the site's original file, unconverted, as an .mkv for VLC or IINA.
- Saved videos open in QuickTime. Video in VP9 (4K and 1440p on most sites, full size Instagram reels, some Facebook videos) is converted with the Mac's own encoder after saving, with progress shown: H.264 up to 1080p, HEVC above it and for HDR, which stays 10-bit. On Macs without AV1 hardware, AV1 versions aren't chosen.
- A copied link from a video site is looked up as the notch opens (without browser cookies), so its card lists the same sizes and starts sooner.
- A link inside copied text (a chat message, a share sheet) is found and offered.
- Japanese, Hindi and other languages only Apple's speech recognition covers are picked on Automatic when the site says the video is in that language.
- Saved files carry their size in the name ("720p", "4K Original", "Audio"), so saving the same video again at another size makes a new file.

### Fixed
- TikTok transcripts and audio used the post's background song instead of what is said in the video.
- Transcribing a dubbed video could use a dub instead of the original language.
- Saving audio or transcribing anything over about an hour stopped with "check your connection" while the audio was being processed. Transcription no longer turns the site's audio into a full size WAV file first.
- Subtitles made downloads fail with "Too Many Requests" and left loose .vtt files. They are now built into the video, where QuickTime shows them.
- Phone shaped videos were saved smaller than the chosen quality (a Short on 1080p came out at 480p).
- Cancelled or failed downloads left partial files in the save folder.
- Live streams were recorded until the download timed out. They now get a clear message.
- File names lost letters like å, ä and ö and titles in other scripts. Transcripts are named like the video they come from.
- Clearer messages for sign in walls (Instagram, Facebook, age restricted videos), removed and private videos, DRM services and unsupported sites, with New Link instead of Try Again when trying again can't help, and Choose Folder when the save folder is missing.
- The video length was missing on YouTube cards, and the progress bar ran twice for videos with separate sound.
- The Mac could go to sleep in the middle of a long job.
- A missing or read only save folder is caught before the job starts instead of after.
- Tracking parameters are removed from links, so the Source line in a copied transcript stays clean.
- vimeo.com links, unlisted ones included, work again without signing in (they now open through Vimeo's player page).

## 3.0.1 (2026-10-26)

### Added
- A new introduction you do instead of read: the notch closes so you open it yourself, a short sample in Mathias's voice plays while its transcript appears line by line, and you paste it with ⌘V right in the notch.
- Show All in Finder at the end of Recent.

### Fixed
- ⌘V could paste into another app when MindExtract believed it was active but another app still had the keyboard, for example with two screens.
- No notification or permission prompt pops up during the introduction.

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
