import SwiftUI

// MARK: - First run, inside the notch
//
// With no Dock icon and no window, the notch has to introduce itself. On first
// launch it opens on its own and walks through four short steps, in the same
// black and white as everything else. It can be shown again from Settings.

enum Onboarding {
    static let seenKey = "hasSeenNotchOnboarding"

    enum Page { case notch, link, paste, meetings, privacy }

    /// Someone coming from 2.x also hears where meetings went.
    @MainActor static let order: [Page] = TranscriptionHistoryManager.shared.hasOldMeetings
        ? [.notch, .link, .paste, .meetings, .privacy]
        : [.notch, .link, .paste, .privacy]
    @MainActor static var pages: Int { order.count }

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    @MainActor
    static func start() {
        NotchModel.shared.onboardingStep = 0
        NotchController.shared.open(.reopen)
    }

    @MainActor
    static func finish() {
        UserDefaults.standard.set(true, forKey: seenKey)
        withAnimation(NotchStyle.snappy) { NotchModel.shared.onboardingStep = nil }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: NotchModel
    let step: Int

    private var page: Onboarding.Page { Onboarding.order[min(step, Onboarding.pages - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                switch page {
                case .notch: NotchIllustration()
                case .link: LinkIllustration()
                case .paste: PasteIllustration()
                case .meetings: MeetingsIllustration()
                case .privacy: PrivacyIllustration()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous).fill(Color.white.opacity(0.05)))
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .opacity.animation(.easeOut(duration: 0.06))))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(NotchStyle.body)
                    .foregroundStyle(NotchStyle.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id("text\(step)")
            .transition(NotchStyle.swap)

            if page == .meetings {
                ChipButton(icon: "folder", title: String(localized: "Show My Old Recordings")) {
                    let folder = TranscriptionHistoryManager.recordingsFolder
                    if FileManager.default.fileExists(atPath: folder.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: AppSettings.shared.downloadPath))
                    }
                }
                .transition(NotchStyle.swap)
            }
            if step == Onboarding.pages - 1 { SetupRows().transition(NotchStyle.swap) }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<Onboarding.pages, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? NotchStyle.text : Color.white.opacity(0.22))
                            .frame(width: i == step ? 16 : 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(String(localized: "Step \(step + 1) of \(Onboarding.pages)"))
                Spacer()
                if step < Onboarding.pages - 1 {
                    ChipButton(icon: "forward.end", title: String(localized: "Skip")) { Onboarding.finish() }
                }
                Button {
                    if step < Onboarding.pages - 1 {
                        withAnimation(NotchStyle.snappy) { model.onboardingStep = step + 1 }
                    } else {
                        Onboarding.finish()
                    }
                } label: {
                    Text(step < Onboarding.pages - 1 ? "Next" : "Get Started").frame(minWidth: 96)
                }
                .buttonStyle(NotchButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .animation(NotchStyle.snappy, value: step)
    }

    private var title: LocalizedStringKey {
        switch page {
        case .notch: return "MindExtract lives in the notch"
        case .link: return "Paste a link or drag a file here"
        case .paste: return "The text lands on your clipboard"
        case .meetings: return "Meeting recording is gone"
        case .privacy: return "Everything stays on your Mac"
        }
    }

    private var message: String {
        switch page {
        case .notch:
            let key = GlobalHotKey.shared.combo?.display
            return key.map { String(localized: "Rest the pointer on the notch or click it. You can also press \($0) from any app.") }
                ?? String(localized: "Rest the pointer on the notch or click it. It works from any app.")
        case .link:
            return String(localized: "YouTube and over a thousand other sites. If you've already copied a link, one click is enough. Save the video too, if you want it.")
        case .paste:
            return String(localized: "When the transcript is done it's copied automatically. Paste it with ⌘V in Claude, ChatGPT or anywhere you like.")
        case .meetings:
            return String(localized: "MindExtract now does one thing well: videos and recordings in, text out. Your old meetings are still on this Mac, untouched.")
        case .privacy:
            return String(localized: "Transcribing happens on this Mac and nothing is uploaded. Only the video itself is fetched from the site.")
        }
    }
}

/// The last page: what's being set up, so nothing comes as a surprise.
private struct SetupRows: View {
    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var loginOn = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            row(icon: "waveform", title: "Speech model",
                detail: tm.isModelInstalled ? "Ready. 25 languages, on this Mac." : "630 MB, downloaded once. Keep working meanwhile.") {
                if tm.isModelInstalled {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                } else {
                    ModelAction()
                }
            }
            row(icon: "power", title: "Open at login", detail: "So the notch is there after a restart.") {
                Toggle("", isOn: Binding(get: { loginOn }, set: { loginOn = $0; LoginItem.set($0) }))
                    .toggleStyle(MonoToggleStyle())
            }
        }
        .background(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func row<Control: View>(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchStyle.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(NotchStyle.small).foregroundStyle(NotchStyle.secondary)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Illustrations (black and white, a little motion)

/// A screen edge with the notch and a pointer resting on it.
private struct NotchIllustration: View {
    @State private var on = false

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1).offset(y: 18)
            NotchShape(top: on ? 7 : 4, bottom: on ? 14 : 7)
                .fill(Color.black)
                .overlay(NotchShape(top: on ? 7 : 4, bottom: on ? 14 : 7).stroke(Color.white.opacity(0.35), lineWidth: 1))
                .frame(width: on ? 190 : 96, height: on ? 54 : 18)
                .offset(y: 18)
            Image(systemName: "cursorarrow")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NotchStyle.text)
                .offset(x: on ? 6 : 70, y: on ? 26 : 62)
        }
        .frame(height: 96, alignment: .top)
        .onAppear { loop() }
    }

    private func loop() {
        guard !NotchStyle.reduceMotion else { on = true; return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.4)) { on = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation(.easeInOut(duration: 0.35)) { on = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { loop() }
        }
    }
}

/// A link field filling in, and a file dropping toward it.
private struct LinkIllustration: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
                Text(verbatim: on ? "youtube.com/watch?v=…" : "")
                    .font(.system(size: 13))
                    .frame(width: 150, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous).fill(NotchStyle.field))
            Text("or").font(NotchStyle.small).foregroundStyle(NotchStyle.tertiary)
            Image(systemName: "film")
                .font(.system(size: 26, weight: .regular))
                .offset(y: on ? 0 : -14)
                .opacity(on ? 1 : 0.4)
        }
        .onAppear { loop() }
    }

    private func loop() {
        guard !NotchStyle.reduceMotion else { on = true; return }
        withAnimation(.easeOut(duration: 0.5).delay(0.3)) { on = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.3)) { on = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loop() }
        }
    }
}

/// The transcript, then ⌘V into a chat.
private struct PasteIllustration: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text").font(.system(size: 26, weight: .regular))
            Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
            HStack(spacing: 4) {
                KeyCap("⌘")
                KeyCap("V")
            }
            .scaleEffect(on ? 0.94 : 1)
            Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 24, weight: .regular))
                .opacity(on ? 1 : 0.4)
        }
        .onAppear { loop() }
    }

    private func loop() {
        guard !NotchStyle.reduceMotion else { on = true; return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6).delay(0.6)) { on = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.3)) { on = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { loop() }
        }
    }
}

private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
    }
}

/// A calendar crossed out, and a film: what it does now.
private struct MeetingsIllustration: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(NotchStyle.tertiary)
                .overlay(Rectangle().fill(NotchStyle.tertiary).frame(width: 44, height: 1.5).rotationEffect(.degrees(-30)))
            Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
            Image(systemName: "film").font(.system(size: 26, weight: .regular))
            Image(systemName: "doc.text").font(.system(size: 26, weight: .regular))
        }
    }
}

/// A laptop with a lock: it stays here.
private struct PrivacyIllustration: View {
    var body: some View {
        ZStack {
            Image(systemName: "laptopcomputer").font(.system(size: 44, weight: .light)).foregroundStyle(NotchStyle.secondary)
            Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold)).offset(y: -4)
        }
    }
}
