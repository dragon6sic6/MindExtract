import SwiftUI
import AppKit

// MARK: - "Allow MindExtract to transcribe your meetings"
//
// One calm screen with everything recording needs, each in plain words with one
// button. Shown on first launch, and whenever Record is pressed without the
// permissions it needs.

extension Notification.Name {
    /// Ask the main window to show the permissions sheet.
    static let showPermissions = Notification.Name("showPermissions")
}

struct PermissionsOnboardingView: View {
    var onDone: () -> Void

    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var askedForMeetingAudio = false

    private var ready: Bool { recorder.micGranted && recorder.screenGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Let MindExtract transcribe your meetings")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text("MindExtract listens through your Mac. No bot joins the meeting, and nothing leaves your computer.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                row("Transcribe your voice", systemImage: "mic", granted: recorder.micGranted,
                    button: "Allow Microphone") {
                    Task {
                        let ok = await recorder.requestMicPermission()
                        if !ok { recorder.openMicSettings() }
                    }
                }
                Divider()
                row("Transcribe the others in the meeting", systemImage: "speaker.wave.2", granted: recorder.screenGranted,
                    button: "Allow Meeting Audio") {
                    recorder.requestScreenPermission()
                    recorder.openScreenRecordingSettings()
                    askedForMeetingAudio = true
                }
                if askedForMeetingAudio && !recorder.screenGranted {
                    HStack {
                        Text("Turned it on in System Settings? Restart MindExtract so it takes effect.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart") { RecordingView.relaunch() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
                Divider()
                row("See who's in the meeting", systemImage: "calendar", granted: calendar.accessGranted,
                    button: "Allow Calendar",
                    help: "Meeting titles and participants come from your calendar invite. Optional.") {
                    Task {
                        await calendar.requestAccess()
                        if calendar.accessGranted { calendar.startMonitoring() }
                    }
                }
                if !tm.isModelDownloaded(.pianissimo) {
                    Divider()
                    modelRow
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.rowFill))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 0.5))

            HStack {
                Button("Later") { onDone() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(36)
        .frame(width: 620)
        .onAppear {
            recorder.refreshPermissions()
            calendar.refreshAccessStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recorder.refreshPermissions()
            calendar.refreshAccessStatus()
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, granted: Bool,
                     button: LocalizedStringKey, help: LocalizedStringKey? = nil,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let help {
                    Text(help).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body.weight(.medium))
            } else {
                Button(action: action) {
                    Label(button, systemImage: systemImage)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var modelRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Swedish at its best").font(.body.weight(.medium))
                Text("The Pianissimo speech model, \(WhisperModel.pianissimo.sizeDescription). Downloads once, then works offline.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if tm.downloadingModel == .pianissimo {
                ProgressView(value: tm.modelDownloadProgress).frame(width: 110)
            } else {
                Button {
                    tm.downloadModel(.pianissimo)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(tm.downloadingModel != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
