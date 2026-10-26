# CI

`.github/workflows/tests.yml` builds the app and runs the unit tests on
GitHub's `macos-26` runner for every push to `master` and every pull request.

- The bundled yt-dlp is fetched with `scripts/setup-tools.sh ytdlp`. ffmpeg
  takes long to build and the tests never run it, so CI uses empty stand-ins.
- Code signing is off in CI. Releases are signed and notarized locally with
  `scripts/release.sh`.
- Tests that need the 630 MB speech model or real recordings are opt-in
  (`SPEECH_E2E_AUDIO`, `CONVERT_E2E_AUDIO`) and skip in CI.

Run the same locally:

```bash
xcodebuild test -project MindExtract.xcodeproj -scheme MindExtract -destination 'platform=macOS'
```
