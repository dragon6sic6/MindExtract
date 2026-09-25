import SwiftUI

// MARK: - The one "transcribe this" sheet
//
// Used for imported files/links and (when "Ask before transcribing" is on, or no
// engine is ready yet) for a finished recording. It only asks what matters for
// this one item — name, spoken language, translation — and downloads a speech
// model inline when one is needed. It never changes the app's settings.

struct TranscribeSheet: View {
    enum Mode {
        case importMedia
        case recording(MeetingRecorder.PendingRecording)
    }

    let mode: Mode
    var initialLanguage: String = AppSettings.shared.defaultTranscriptionLanguage
    /// name (recordings only), spoken language, model.
    let onStart: (_ name: String?, _ language: String, _ model: WhisperModel) -> Void
    /// Import: cancel. Recording: discard (after confirmation).
    let onCancel: () -> Void

    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var name = ""
    @State private var language = "auto"
    @State private var translate = false
    @State private var chosenModel: WhisperModel = .small
    @State private var modelTouched = false
    @State private var appleSupportsLanguage = false
    @State private var awaitingDownload: WhisperModel?
    @State private var confirmingDiscard = false

    private var isRecording: Bool {
        if case .recording = mode { return true }
        return false
    }

    /// Will a downloadable model (not Apple's built-in speech) run this?
    private var needsSpeechModel: Bool {
        let engine = AppSettings.shared.transcriptionEngine
        if engine == .whisperKit || translate || !tm.useAppleSpeech() { return true }
        if language == "sv" && engine != .appleSpeech { return true }   // Pianissimo
        return !appleSupportsLanguage
    }

    private var needsDownload: Bool { needsSpeechModel && !tm.isModelDownloaded(chosenModel) }
    private var isDownloading: Bool { tm.downloadingModel == chosenModel }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if case .recording(let pending) = mode {
                    Section {
                        TextField("Name", text: $name)
                    } header: {
                        Text("Recording finished · \(RecordingView.formatElapsed(pending.duration))")
                    }
                }
                Section {
                    Picker("Spoken language", selection: $language) {
                        ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                            Text(verbatim: lang.name).tag(lang.code)
                        }
                    }
                    Toggle(isOn: $translate) {
                        Text("Translate to English")
                        Text("The transcript is written in English, whatever language is spoken.")
                    }
                } footer: {
                    Text("Runs on your Mac. Nothing is uploaded.")
                }
                if needsSpeechModel {
                    Section {
                        Picker("Speech model", selection: Binding(
                            get: { chosenModel },
                            set: { chosenModel = $0; modelTouched = true })) {
                            ForEach(modelChoices) { m in
                                Text(modelLabel(m)).tag(m)
                            }
                        }
                        if isDownloading {
                            ProgressView(value: tm.modelDownloadProgress) {
                                Text("Downloading \(chosenModel.displayName)…")
                            }
                        } else if needsDownload {
                            Label("\(chosenModel.displayName) (\(chosenModel.sizeDescription)) downloads once, then works offline.",
                                  systemImage: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                        }
                        if case .error(let message) = tm.transcriptionState, awaitingDownload != nil {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                if isRecording {
                    Button("Discard…", role: .destructive) { confirmingDiscard = true }
                }
                Spacer()
                if !isRecording {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(needsDownload ? "Download and Transcribe" : "Transcribe", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            language = initialLanguage
            if case .recording(let pending) = mode { name = pending.title }
            chosenModel = defaultModel(for: language)
            refreshAppleSupport()
        }
        .onChange(of: language) { _, lang in
            if !modelTouched { chosenModel = defaultModel(for: lang) }
            refreshAppleSupport()
        }
        .onChange(of: translate) { _, _ in
            if !modelTouched { chosenModel = defaultModel(for: language) }
        }
        .onChange(of: tm.downloadedModels) { _, models in
            if let waiting = awaitingDownload, models.contains(waiting) {
                awaitingDownload = nil
                finish(with: waiting)
            }
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive, action: onCancel)
        } message: {
            Text("The audio is deleted. This can't be undone.")
        }
    }

    // MARK: Models

    private var modelChoices: [WhisperModel] {
        WhisperModel.allCases.filter { !$0.isSwedishOnly || language == "sv" || language == "auto" }
    }

    private func defaultModel(for lang: String) -> WhisperModel {
        let rec = WhisperModel.recommended(for: lang)
        if translate { return tm.isModelDownloaded(AppSettings.shared.defaultWhisperModel) ? AppSettings.shared.defaultWhisperModel : .small }
        if tm.isModelDownloaded(rec) { return rec }
        let def = AppSettings.shared.defaultWhisperModel
        return tm.isModelDownloaded(def) && !rec.isSwedishOnly ? def : rec
    }

    private func modelLabel(_ m: WhisperModel) -> String {
        tm.isModelDownloaded(m)
            ? m.displayName
            : String(localized: "\(m.displayName) · \(m.sizeDescription) download")
    }

    private func refreshAppleSupport() {
        let lang = language
        Task {
            let ok = await TranscriptionManager.appleSpeechSupports(lang)
            appleSupportsLanguage = ok
        }
    }

    // MARK: Actions

    private func start() {
        if needsDownload {
            awaitingDownload = chosenModel
            tm.downloadModel(chosenModel)
        } else {
            finish(with: chosenModel)
        }
    }

    private func finish(with model: WhisperModel) {
        // Translation is a one-off for this item; the pipeline resets it afterwards.
        UserDefaults.standard.set(translate, forKey: "translateToEnglish")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onStart(isRecording ? trimmed : nil, language, model)
    }

    private func cancel() {
        if isDownloading {
            tm.cancelModelDownload()
            awaitingDownload = nil
        } else {
            onCancel()
        }
    }
}
