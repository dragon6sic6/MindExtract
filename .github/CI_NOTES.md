# CI notes

Hosted GitHub Actions CI is **not currently possible**: the app references
macOS 26 SDK symbols (SpeechAnalyzer / SpeechTranscriber, runtime-gated with
`@available`). GitHub's `macos-15` runners ship Xcode 16.4 / MacOSX15.5 SDK,
which lacks those symbols, so the build fails to compile on hosted runners.

Guardrail today: the unit-test suite runs locally —
`xcodebuild test -project MindExtract.xcodeproj -scheme MindExtract -destination 'platform=macOS'`
(run before every release).

Re-enable hosted CI when either:
- GitHub offers a runner image with an Xcode that has the macOS 26 SDK, or
- a **self-hosted runner** is registered on a Mac that has that Xcode
  (then add a workflow with `runs-on: [self-hosted, macOS]`).
