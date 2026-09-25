import SwiftUI

// MARK: - Dictation
//
// The third part of the app: hold right ⌥ anywhere, speak, let go — the text is
// typed where the cursor is. This page explains it, shows whether it's ready,
// and has a box to try it in.

struct DictationPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var practice = ""

    private var ready: Bool { settings.dictationEnabled && dictation.accessibilityGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dictation")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                Text("Hold right ⌥ Option anywhere, speak, and let go. The text is typed where your cursor is — in any app.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                row("Dictation", nil) {
                    Toggle("Dictation", isOn: Binding(
                        get: { settings.dictationEnabled },
                        set: { settings.dictationEnabled = $0; dictation.refresh() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if settings.dictationEnabled {
                    Divider()
                    row("Accessibility", "Lets MindExtract notice the key and type into other apps. It never reads what you type.") {
                        if dictation.accessibilityGranted {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow…") {
                                dictation.requestAccessibility()
                                dictation.openAccessibilitySettings()
                            }
                        }
                    }
                    Divider()
                    row("Language", nil) {
                        Picker("Language", selection: Binding(
                            get: { settings.dictationLanguage },
                            set: { settings.dictationLanguage = $0; dictation.refresh() })) {
                            ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                                Text(verbatim: lang.name).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Divider()
                    row("Engine", "The audio is discarded right after. No AI rewrites your words.") {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(verbatim: engine).fontWeight(.medium)
                            Label("On your Mac", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.rowFill))

            if ready {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Try it")
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $practice)
                            .font(.title3)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 120)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.inputFill))
                            .accessibilityLabel("Try dictation here")
                        if practice.isEmpty {
                            Text("Click here, hold right ⌥ and say something.")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 15).padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }

            if !dictation.recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Recent", count: dictation.recent.count)
                    ForEach(dictation.recent) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: entry.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { dictation.copy(entry) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy")
                                .accessibilityLabel("Copy")
                        }
                        .padding(12)
                        .rowChrome()
                    }
                    Text("Kept until you quit, in case the text landed where there was no text field.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .pageLayout()
        .onAppear { dictation.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dictation.refresh()
        }
    }

    private var engine: String {
        if settings.dictationLanguage == "sv", tm.isModelDownloaded(.pianissimo) { return "Pianissimo" }
        return "Whisper · \(tm.multilingualBaseModel().displayName)"
    }

    private func row<Control: View>(_ title: LocalizedStringKey, _ detail: LocalizedStringKey?,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
