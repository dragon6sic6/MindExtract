import SwiftUI
import AVFoundation

// MARK: - Recording surface (in-app)

struct RecordingView: View {
    var onOpenTranscripts: () -> Void = {}

    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var live = MeetingRecorder.shared.live
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var captionOverlay = CaptionOverlayController.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var activeMeeting = ActiveMeetingDetector.shared

    @State private var startLanguage: String = ""
    private let languages = AppSettings.transcriptionLanguages

    /// The model used for the live preview — the recommended model for the chosen
    /// language, but only if it's already downloaded (live needs it immediately).
    private var liveModel: WhisperModel? {
        let rec = WhisperModel.recommended(for: startLanguage)
        return transcriptionManager.downloadedModels.contains(rec) ? rec : nil
    }

    private func resolvedStartLanguage() -> String {
        let pref = AppSettings.shared.defaultTranscriptionLanguage
        if pref != "auto" { return pref }
        let sys = Locale.current.language.languageCode?.identifier ?? "auto"
        return languages.contains { $0.code == sys } ? sys : "auto"
    }

    var body: some View {
        Group {
            if MeetingRecorder.isSupported {
                content
            } else {
                unsupported
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Offer to recover a recording interrupted by a crash/force-quit; start
        // calendar monitoring so we can suggest the meeting you're in.
        .onAppear {
            if MeetingRecorder.isSupported {
                recorder.recoverInterruptedSessions()
                calendar.refreshAccessStatus()
                if calendar.accessGranted { calendar.startMonitoring() }
                activeMeeting.startMonitoring()
            }
        }
        // Keep call detection alive while it's enabled — its Settings toggle implies
        // a persistent mode, so leaving the Record tab shouldn't silently kill it.
        .onDisappear {
            calendar.stopMonitoring()
            if !settings.detectActiveMeetings { activeMeeting.stopMonitoring() }
        }
        // Auto-record (opt-in): start when a meeting/call is detected, once each.
        .onChange(of: calendar.currentMeeting) { _, _ in autoRecordIfNeeded() }
        .onChange(of: activeMeeting.activeApp) { _, _ in autoRecordIfNeeded() }
        // Floating captions follow the recording lifecycle: auto-show on start if
        // the user enabled it, and always hide when the live transcriber stops
        // (Stop button, menu bar, sleep, error, …).
        .onChange(of: live.isActive) { _, active in
            if active {
                if AppSettings.shared.autoShowCaptions { captionOverlay.show(transcriber: live) }
            } else {
                captionOverlay.hide()
            }
        }
        // When a finished recording kicks off transcription, jump to Transcripts.
        .onChange(of: transcriptionManager.showTranscriptionView) { _, shown in
            if shown { onOpenTranscripts() }
        }
        // Confirm / name / discard a finished recording before transcribing.
        .sheet(item: $recorder.pendingRecording) { pending in
            RecordingConfirmSheet(
                pending: pending,
                onTranscribe: { name, lang, model in recorder.confirmPending(title: name, language: lang, model: model) },
                onDiscard: { recorder.discardPending() }
            )
            .interactiveDismissDisabled()
        }
    }

    // MARK: Supported

    private var content: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(recorder.isRecording ? Color.red : DS.Colors.accent)
                Text("Record a meeting")
                    .font(.title2).fontWeight(.semibold)
                Text("Captures the meeting audio and your microphone — fully on your Mac. No bot joins the call, nothing is uploaded.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            if recorder.isRecording {
                recordingPanel
            } else if recorder.state == .finishing {
                finalizingPanel
            } else {
                idlePanel
            }

            if case .error(let message, let kind) = recorder.state {
                errorPanel(message, kind)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: Idle

    private var idlePanel: some View {
        VStack(spacing: 18) {
            activeCallCard
            calendarCard
            permissionRows

            if !recorder.screenGranted {
                Text("After enabling Screen Recording in System Settings, relaunch MindExtract for it to take effect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("Relaunch MindExtract") { Self.relaunch() }
                .secondaryGlassButton()
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("Language").font(.system(size: 13)).foregroundColor(.secondary)
                Picker("", selection: $startLanguage) {
                    ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            Button {
                recorder.start(language: startLanguage, liveModel: liveModel)
            } label: {
                Label(recorder.state == .starting ? "Starting…" : "Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: 260)
            }
            .primaryGlassButton()
            .controlSize(.large)
            .disabled(recorder.isBusy)

            Text(liveModel != nil
                 ? "Live transcript on — \(liveModel!.displayName.replacingOccurrences(of: " (Swedish)", with: ""))"
                 : "Live transcript off — download a model (transcribe a file once) to see text as you record.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Text("Tip: you can also start and stop from the menu bar during a call.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .onAppear { if startLanguage.isEmpty { startLanguage = resolvedStartLanguage() } }
    }

    /// Shown when a call app (Zoom/Teams/…) is detected in an active call — works
    /// regardless of calendar provider, and even with no calendar event at all.
    @ViewBuilder
    private var activeCallCard: some View {
        if let app = activeMeeting.activeApp, calendar.currentMeeting == nil {
            let headline = activeMeeting.activeIsBrowser ? "Call active in \(app)" : "\(app) is in a call"
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live call detected").font(.caption).foregroundColor(.secondary)
                        Text(headline).font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                }
                Button {
                    let title = activeMeeting.activeIsBrowser ? "Video call" : "\(app) call"
                    recorder.start(language: startLanguage, liveModel: liveModel, meetingTitle: title)
                } label: {
                    Label("Record this call", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .primaryGlassButton().controlSize(.large).disabled(recorder.isBusy)
            }
            .padding(12)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.3), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var calendarCard: some View {
        if let m = calendar.currentMeeting {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18)).foregroundStyle(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.isLive ? "Happening now" : "Starting soon")
                            .font(.caption).foregroundColor(.secondary)
                        Text(m.title).font(.system(size: 14, weight: .semibold))
                        if !m.attendees.isEmpty {
                            Text("^[\(m.attendees.count) attendee](inflect: true)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                Button { startMeeting(m) } label: {
                    Label("Record this meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .primaryGlassButton().controlSize(.large).disabled(recorder.isBusy)
            }
            .padding(12)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.Colors.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Colors.accent.opacity(0.3), lineWidth: 1))
        } else if settings.calendarSuggestionsEnabled && !calendar.accessGranted {
            Button {
                Task { await calendar.requestAccess(); if calendar.accessGranted { calendar.startMonitoring() } }
            } label: {
                Label("Connect calendar to auto-suggest meetings", systemImage: "calendar")
            }
            .secondaryGlassButton().controlSize(.small)
        }
    }

    @State private var lastAutoRecordKey: String?

    /// Auto-start recording when a meeting/call is detected (opt-in). Triggers at
    /// most once per distinct detection, and never while already busy.
    private func autoRecordIfNeeded() {
        guard settings.autoRecordMeetings, !recorder.isBusy else { return }
        if let m = calendar.currentMeeting {
            guard lastAutoRecordKey != m.id else { return }
            lastAutoRecordKey = m.id
            startMeeting(m)
        } else if let app = activeMeeting.activeApp {
            let key = "call:\(app)"
            guard lastAutoRecordKey != key else { return }
            lastAutoRecordKey = key
            recorder.start(language: startLanguage, liveModel: liveModel, meetingTitle: "\(app) call")
        }
    }

    private func startMeeting(_ m: MeetingCalendar.CalEvent) {
        let prefill = m.attendees.isEmpty ? "" : "Attendees: " + m.attendees.joined(separator: ", ") + "\n\n"
        recorder.start(language: startLanguage, liveModel: liveModel, meetingTitle: m.title, notesPrefill: prefill, attendees: m.attendees, attendeeEmails: m.attendeeEmails)
    }

    private var finalizingPanel: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Finalizing recording…")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text("Saving and preparing the audio. This can take a moment for long meetings.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(.vertical, 20)
    }

    // MARK: Recording

    private var recordingPanel: some View {
        VStack(spacing: 18) {
            Text(Self.formatElapsed(recorder.elapsed))
                .font(.system(size: 40, weight: .light, design: .monospaced))
                .foregroundColor(.primary)

            LevelMeter(level: recorder.level)
                .frame(width: 260, height: 8)

            HStack(spacing: 16) {
                sourceTag("Microphone", active: recorder.micActive)
                sourceTag("Meeting audio", active: recorder.systemActive)
            }

            if live.isActive {
                liveTranscriptView
                Button {
                    captionOverlay.toggle(transcriber: live)
                } label: {
                    Label(captionOverlay.isVisible ? "Hide floating captions" : "Show floating captions",
                          systemImage: captionOverlay.isVisible ? "rectangle.slash" : "captions.bubble")
                        .font(.caption)
                }
                .secondaryGlassButton()
                .controlSize(.small)
                .help("Show live captions in a floating window that stays on top of Zoom/Teams")
            }

            // Bookmark "this matters" → jumps appear in the Brief afterwards.
            Button {
                recorder.markMoment()
            } label: {
                Label(recorder.markedMoments.isEmpty ? "Mark moment  ⌘M" : "Mark moment  ⌘M  ·  \(recorder.markedMoments.count)",
                      systemImage: "flag.fill")
                    .font(.caption)
            }
            .secondaryGlassButton()
            .controlSize(.small)
            .help("Bookmark this moment — you can jump back to it in the Brief")

            liveNotesView

            Button {
                recorder.stop()
            } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill")
                    .frame(maxWidth: 260)
            }
            .primaryGlassButton()
            .controlSize(.large)
        }
    }

    private var liveNotesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").font(.system(size: 11)).foregroundStyle(DS.Colors.accent)
                Text("Your notes — AI merges these with the transcript")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            TextEditor(text: $recorder.liveNotes)
                .font(.system(size: 13))
                .frame(width: 520, height: 90)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        }
    }

    private var liveTranscriptView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(DS.Colors.accent)
                Text(live.displayText.isEmpty ? (live.status.isEmpty ? "Listening…" : live.status) : "Live transcript")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(live.displayText.isEmpty ? " " : live.displayText)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("liveBottom")
                }
                .frame(width: 520, height: 150)
                .onChange(of: live.displayText) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("liveBottom", anchor: .bottom) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        }
    }

    private func sourceTag(_ title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundColor(active ? .primary : .secondary)
        }
    }

    // MARK: Permissions

    private var permissionRows: some View {
        VStack(spacing: 10) {
            permissionRow(
                title: "Screen Recording",
                detail: "Lets MindExtract hear the meeting audio — audio only, no video is captured.",
                granted: recorder.screenGranted,
                action: { recorder.requestScreenPermission(); recorder.openScreenRecordingSettings() }
            )
            permissionRow(
                title: "Microphone",
                detail: "Lets MindExtract hear your voice — stays on your Mac.",
                granted: recorder.micGranted,
                action: {
                    Task {
                        let ok = await recorder.requestMicPermission()
                        if !ok { recorder.openMicSettings() }
                    }
                }
            )
        }
        .frame(maxWidth: 460)
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .secondaryGlassButton()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }

    // MARK: Error

    private func errorPanel(_ message: String, _ kind: MeetingRecorder.ErrorKind) -> some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 8) {
                switch kind {
                case .screenPermission:
                    Button("Open Settings") { recorder.openScreenRecordingSettings() }
                        .secondaryGlassButton().controlSize(.small)
                case .micPermission:
                    Button("Open Settings") { recorder.openMicSettings() }
                        .secondaryGlassButton().controlSize(.small)
                case .capture:
                    EmptyView()
                }
                Button("Dismiss") { recorder.dismissError() }
                    .secondaryGlassButton()
                    .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Unsupported

    private var unsupported: some View {
        VStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Meeting recording requires macOS 15")
                .font(.title3).fontWeight(.semibold)
            Text("On-device capture of both the meeting audio and your microphone needs macOS 15 or later. Everything else in MindExtract works on your current version.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }

    /// Relaunch the app (needed for the Screen Recording permission to take effect).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Confirm sheet (name / transcribe / discard)

private struct RecordingConfirmSheet: View {
    let pending: MeetingRecorder.PendingRecording
    let onTranscribe: (String, String, WhisperModel) -> Void
    let onDiscard: () -> Void

    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var name: String = ""
    @State private var language: String = ""
    @State private var confirmingDiscard = false
    @State private var appleSupported = false   // conservative until the async check resolves
    @State private var awaitingModelDownload: WhisperModel?   // the model a tapped download is for
    @State private var selectedModel: WhisperModel = .small

    private let languages = AppSettings.transcriptionLanguages

    /// This language is transcribed by WhisperKit (Apple Speech can't do it), so
    /// we always let the user pick the model — KB-Whisper is recommended for Swedish.
    private var usesWhisperKit: Bool { !appleSupported }
    /// The chosen model isn't downloaded yet → offer to download it first.
    private var needsDownload: Bool { usesWhisperKit && !tm.downloadedModels.contains(selectedModel) }
    private var isDownloadingModel: Bool { tm.downloadingModel != nil }

    /// Models offered for the chosen language — KB-Whisper only appears for Swedish.
    private var modelChoices: [WhisperModel] {
        WhisperModel.allCases.filter { !$0.isSwedishOnly || language == "sv" }
    }

    /// Menu label for a model — section headers carry the Swedish/general context,
    /// so strip the "(Swedish)" suffix here to avoid redundancy.
    private func modelLabel(_ m: WhisperModel) -> String {
        let rec = (m == WhisperModel.recommended(for: language))
        let have = tm.downloadedModels.contains(m)
        let name = m.displayName.replacingOccurrences(of: " (Swedish)", with: "")
        return "\(name) · \(m.sizeDescription)\(rec ? " · Recommended" : "")\(have ? " · Installed" : "")"
    }

    /// Smart default: the saved preference if set, else the system language if we
    /// support it, else auto. Picking the actual language is what makes Swedish
    /// (etc.) transcribe correctly instead of being guessed as English.
    private static func defaultLanguage() -> String {
        let pref = AppSettings.shared.defaultTranscriptionLanguage
        if pref != "auto" { return pref }
        let sys = Locale.current.language.languageCode?.identifier ?? "auto"
        return AppSettings.transcriptionLanguages.contains { $0.code == sys } ? sys : "auto"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DS.Colors.accent)
                Text("Recording finished")
                    .font(.title3).fontWeight(.semibold)
                Text(RecordingView.formatElapsed(pending.duration) + " · stays on your Mac")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 22).padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.system(size: 13, weight: .semibold))
                    TextField("Recording name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spoken language").font(.system(size: 13, weight: .semibold))
                        Text("Set this to the language spoken in the meeting.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $language) {
                        ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                if usesWhisperKit {
                    if isDownloadingModel {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Downloading \(selectedModel.displayName) model… \(Int(tm.modelDownloadProgress * 100))%")
                                .font(.caption).foregroundColor(.secondary)
                            ProgressView(value: tm.modelDownloadProgress).tint(DS.Colors.accent)
                            Text("Transcription starts automatically when it's ready.")
                                .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(languageName) is transcribed by WhisperKit. Pick a model — KB-Whisper is best for Swedish; larger is more accurate, smaller is faster.")
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Model").font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Picker("", selection: $selectedModel) {
                                    let kb = modelChoices.filter { $0.isSwedishOnly }
                                    let general = modelChoices.filter { !$0.isSwedishOnly }
                                    if !kb.isEmpty {
                                        Section("Best for Swedish") {
                                            ForEach(kb) { Text(modelLabel($0)).tag($0) }
                                        }
                                    }
                                    Section("General — OpenAI Whisper") {
                                        ForEach(general) { Text(modelLabel($0)).tag($0) }
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 320)
                            }
                            Text(selectedModel.description)
                                .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                            if language == "sv" {
                                Text("KB-Whisper is trained on Swedish by the National Library of Sweden (KBLab) — markedly more accurate on Swedish than the standard models.")
                                    .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(20)

            Divider()

            HStack(spacing: 10) {
                Button(role: .destructive) { confirmingDiscard = true } label: {
                    Label("Discard", systemImage: "trash")
                }
                .secondaryGlassButton()
                .controlSize(.large)
                .confirmationDialog("Discard this recording? The audio will be deleted.",
                                    isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard Recording", role: .destructive) {
                        if tm.downloadingModel != nil { tm.cancelModelDownload() }
                        awaitingModelDownload = nil
                        onDiscard()
                    }
                    Button("Keep", role: .cancel) {}
                }

                Button {
                    if needsDownload {
                        awaitingModelDownload = selectedModel
                        tm.downloadModel(selectedModel)
                    } else {
                        onTranscribe(name, language, selectedModel)
                    }
                } label: {
                    Label(needsDownload ? (isDownloadingModel ? "Downloading…" : "Download & Transcribe") : "Transcribe",
                          systemImage: needsDownload ? "arrow.down.circle.fill" : "waveform")
                        .frame(maxWidth: .infinity)
                }
                .primaryGlassButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
                .disabled(isDownloadingModel)
            }
            .padding(16)
        }
        .frame(width: 420)
        .onAppear {
            if name.isEmpty { name = pending.title }
            if language.isEmpty { language = Self.defaultLanguage() }
            selectedModel = WhisperModel.recommended(for: language)
            refreshAppleSupport()
        }
        .onChange(of: language) { _, newLang in
            selectedModel = WhisperModel.recommended(for: newLang)
            refreshAppleSupport()
        }
        .onChange(of: tm.downloadedModels) { _, models in
            // The EXACT model the download was started for finished → transcribe.
            // (Tracking the specific model avoids firing if the user switched the
            // picker mid-download.)
            if let waiting = awaitingModelDownload, models.contains(waiting) {
                awaitingModelDownload = nil
                onTranscribe(name, language, waiting)
            }
        }
    }

    private var languageName: String {
        languages.first { $0.code == language }?.name ?? language
    }

    private func refreshAppleSupport() {
        if #available(macOS 26.0, *) {
            let lang = language
            Task {
                let ok = await TranscriptionManager.appleSpeechSupports(lang)
                await MainActor.run { appleSupported = ok }
            }
        } else {
            appleSupported = false   // no Apple Speech below macOS 26
        }
    }
}

// MARK: - Level meter

private struct LevelMeter: View {
    let level: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [DS.Colors.accent, .green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * level))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }
}
