import SwiftUI

// MARK: - First run, inside the notch
//
// "Do it, don't read it." Four steps, about a minute:
//
//   1. welcome  The notch introduces itself, then closes so you can open it
//      (summon)  yourself: a breathing rim and a caption point at it.
//   2. tryIt    Your first real transcript, from a copied link or the
//               bundled sample. The speech model's download is its progress.
//   3. paste    The words are already on the clipboard: press ⌘V right here.
//   4. finish   The model, open at login, and for 2.x users their old library.
//
// One black object in the hero changes shape from step to step instead of a
// new illustration on every page. Black and white only.

enum Onboarding {
    static let seenKey = "hasSeenNotchOnboarding"

    enum Beat: Int, CaseIterable {
        case welcome, summon, tryIt, paste, finish

        /// Its segment in the pager. Summoning happens with the notch closed,
        /// as part of the first step.
        var pagerIndex: Int {
            switch self {
            case .welcome, .summon: return 0
            case .tryIt: return 1
            case .paste: return 2
            case .finish: return 3
            }
        }
    }

    static let pagerCount = 4

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    @MainActor private static var model: NotchModel { .shared }

    @MainActor
    static func start() {
        model.clear()
        model.onboardingPaste = nil
        model.onboardingCaption = nil
        model.onboardingJustSummoned = false
        model.onboarding = .welcome
        NotchController.shared.open(.reopen)
    }

    @MainActor
    static func advance(to beat: Beat) {
        tick()
        withAnimation(NotchStyle.snappy) { model.onboarding = beat }
    }

    /// "Show Me": the notch closes and waits for you to open it.
    @MainActor
    static func showMe() {
        model.onboarding = .summon
        model.onboardingCaption = summonCaption
        NotchController.shared.close()
        AccessibilityNotification.Announcement(
            String(localized: "MindExtract is at the top center of the screen. Press Control Option Space to open it.")).post()
    }

    /// You opened it: on to the first transcript.
    @MainActor
    static func summoned(by reason: NotchController.OpenReason) {
        model.onboardingCaption = nil
        model.onboardingJustSummoned = true
        advance(to: .tryIt)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// ⌘V during the paste step lands in the introduction's own field.
    @MainActor
    static func pasteIfWaiting() -> Bool {
        guard model.onboarding == .paste, model.isOpen else { return false }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return false }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(NotchStyle.snappy) { model.onboardingPaste = text }
        return true
    }

    /// Done or skipped. The notch closes with a last word about where it lives.
    @MainActor
    static func finish() {
        UserDefaults.standard.set(true, forKey: seenKey)
        model.onboarding = nil
        model.onboardingPaste = nil
        model.onboardingJustSummoned = false
        model.clear()
        NotchController.shared.close()
        let farewell = String(localized: "I'm up here whenever you need me.")
        model.onboardingCaption = farewell
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if model.onboardingCaption == farewell { model.onboardingCaption = nil }
        }
    }

    @MainActor
    private static var summonCaption: String {
        let place = model.geometry.hasNotch
            ? String(localized: "Rest your pointer on the notch")
            : String(localized: "Rest your pointer at the top center")
        if let key = GlobalHotKey.shared.combo?.display {
            return String(localized: "\(place), or press \(key).")
        }
        return String(localized: "\(place), or click it.")
    }

    @MainActor
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - The introduction in the open notch

struct OnboardingView: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var tm = TranscriptionManager.shared
    let beat: Onboarding.Beat

    /// The clipboard is checked while you're asked for a link, so one you copy
    /// shows up without reopening the notch.
    private let clipboardTimer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HeroStage(beat: beat)
                .frame(height: heroHeight)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                RevealText(copy.title, font: .system(size: 26, weight: .semibold), tracking: -0.5)
                RevealText(copy.body, font: .system(size: 14), color: NotchStyle.secondary, delay: 0.08)
                    .frame(maxWidth: 400)
            }
            .multilineTextAlignment(.center)
            .id(copy.title + copy.body)
            .transition(NotchStyle.swap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            controls
                .padding(.top, 20)
                .transition(NotchStyle.swap)

            Spacer(minLength: 18)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .frame(minHeight: 360)
        .animation(NotchStyle.snappy, value: beat)
        .animation(NotchStyle.snappy, value: model.stage)
        .animation(NotchStyle.snappy, value: model.clipboardLink)
        .animation(NotchStyle.snappy, value: model.onboardingPaste)
        .onReceive(clipboardTimer) { _ in
            if beat == .tryIt, !model.isBusy, case .idle = model.stage { model.refreshClipboard() }
        }
        .onAppear { takeKeyboardIfPasting() }
        .onChange(of: beat) { _, _ in takeKeyboardIfPasting() }
    }

    private func takeKeyboardIfPasting() {
        if beat == .paste { NotchController.shared.takeKeyboardForIntroduction() }
    }

    private var heroHeight: CGFloat {
        switch beat {
        case .welcome, .summon: return 168
        case .tryIt: return 132
        case .paste: return 116
        case .finish: return 104
        }
    }

    // MARK: Words

    private var copy: (title: String, body: String) {
        switch beat {
        case .welcome, .summon:
            return model.geometry.hasNotch
                ? (String(localized: "MindExtract lives in your notch."),
                   String(localized: "No Dock icon and no window. Let's make sure you can always find it."))
                : (String(localized: "MindExtract lives at the top of your screen."),
                   String(localized: "No Dock icon and no window. Let's make sure you can always find it."))
        case .tryIt:
            switch model.stage {
            case .loadingInfo:
                return (String(localized: "Reading the link."), String(localized: "Looking up the video."))
            case .working(_, _, let phase, _):
                return (String(localized: "Turning it into text."), phase)
            case .failed(_, _, let message, _, _):
                return (String(localized: "That didn't work."), message)
            default:
                let lead = model.onboardingJustSummoned ? String(localized: "That's all it takes. ") : ""
                return (String(localized: "Give it something to read."),
                        lead + String(localized: "Copy a video link, or try our short sample."))
            }
        case .paste:
            if model.onboardingPaste != nil {
                return (String(localized: "That's the whole idea."),
                        String(localized: "Paste it into Claude, ChatGPT or anywhere you like, and ask it anything."))
            }
            return (String(localized: "It's already on your clipboard."),
                    String(localized: "\(words) words, ready for Claude or ChatGPT. Press ⌘V to try it here."))
        case .finish:
            return (String(localized: "You're all set."),
                    String(localized: "Transcribing happens on this Mac. Only the video itself is fetched."))
        }
    }

    private var words: Int {
        if case .transcribed(_, let path) = model.stage { return NotchModel.wordCount(ofTranscriptAt: path) }
        return 0
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        switch beat {
        case .welcome, .summon:
            EmptyView()
        case .tryIt:
            TryItControls()
        case .paste:
            PasteWell(text: model.onboardingPaste)
        case .finish:
            FinishCards()
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Pager(index: beat.pagerIndex)
            Spacer()
            if beat != .finish {
                Button { Onboarding.finish() } label: {
                    Text("Skip").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            if let primary {
                Button(action: primary.action) {
                    Text(primary.title).frame(minWidth: 96)
                }
                .buttonStyle(NotchButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 4)
    }

    private var primary: (title: LocalizedStringKey, action: () -> Void)? {
        switch beat {
        case .welcome, .summon: return ("Show Me", { Onboarding.showMe() })
        case .tryIt: return nil   // the choices are the step itself
        case .paste: return ("Next", { Onboarding.advance(to: .finish) })
        case .finish: return ("Done", { Onboarding.finish() })
        }
    }
}

// MARK: - Step 2: a link or the sample

private struct TryItControls: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        switch model.stage {
        case .loadingInfo, .working:
            ChipButton(icon: "xmark", title: String(localized: "Cancel")) { model.cancel() }
        case .failed(_, _, _, let problem, _):
            HStack(spacing: 10) {
                if problem == .needsSpeechModel {
                    Button { model.downloadModelAndContinue() } label: {
                        Label("Download the Speech Model", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
                } else {
                    Button { model.clear(); model.transcribeSample() } label: {
                        Label("Try the Sample", systemImage: "waveform")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
                }
                ChipButton(icon: "arrow.counterclockwise", title: String(localized: "Start Over")) { model.clear() }
            }
        default:
            VStack(spacing: 12) {
                if let link = model.clipboardLink {
                    HStack(spacing: 10) {
                        Button { model.transcribeCopiedLink() } label: {
                            Label("Transcribe the Copied Link", systemImage: "text.badge.plus")
                        }
                        .buttonStyle(NotchButtonStyle(kind: .primary))
                        ChipButton(icon: "waveform", title: String(localized: "Use the Sample")) { model.transcribeSample() }
                    }
                    .accessibilityHint(Text(verbatim: link))
                } else {
                    Button { model.transcribeSample() } label: {
                        Label("Try the Sample", systemImage: "waveform")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
                    WaitingForLink()
                }
            }
        }
    }
}

/// "Or copy a link…" with a slow dot, so it's clear a copied link counts.
private struct WaitingForLink: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(NotchStyle.text)
                .frame(width: 5, height: 5)
                .opacity(on ? 1 : 0.25)
            Text("Or copy a link in your browser. It shows up here.")
                .font(NotchStyle.small)
                .foregroundStyle(NotchStyle.secondary)
        }
        .onAppear {
            guard !NotchStyle.reduceMotion else { on = true; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

// MARK: - Step 3: paste it here

/// Stands in for Claude's message box. ⌘V fills it (NotchPanel hands the paste
/// to `Onboarding.pasteIfWaiting`).
private struct PasteWell: View {
    let text: String?
    @State private var caret = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous)
                    .strokeBorder(Color.white.opacity(text == nil ? 0.16 : 0.10)))
            if let text {
                ScrollView {
                    RevealText(String(text.prefix(1200)), font: .system(size: 12.5), color: NotchStyle.text,
                               alignment: .leading, duration: 1.4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .scrollIndicators(.never)
            } else {
                HStack(spacing: 2) {
                    Text("Pretend this is Claude.")
                        .foregroundStyle(NotchStyle.tertiary)
                    Rectangle()
                        .fill(NotchStyle.text)
                        .frame(width: 1.5, height: 16)
                        .opacity(caret ? 1 : 0)
                }
                .font(.system(size: 13))
                .padding(14)
                .onAppear {
                    guard !NotchStyle.reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { caret = false }
                }
            }
        }
        .frame(height: 124)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text == nil ? String(localized: "Paste area. Press Command V.") : String(localized: "Pasted transcript"))
    }
}

// MARK: - Step 4: the last two things

private struct FinishCards: View {
    @ObservedObject private var tm = TranscriptionManager.shared
    @State private var loginOn = LoginItem.isEnabled
    private let upgrader = TranscriptionHistoryManager.shared.hasOldMeetings

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                row(title: "Speech model",
                    detail: tm.isModelInstalled ? "Ready. 25 languages, on this Mac." : "630 MB. Downloads once.") {
                    if tm.isModelInstalled {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        ModelAction()
                    }
                }
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 16)
                row(title: "Open at login", detail: "So the notch is there after a restart.") {
                    Toggle("", isOn: Binding(get: { loginOn }, set: { loginOn = $0; LoginItem.set($0) }))
                        .toggleStyle(MonoToggleStyle())
                        .environment(\.settingsRowTitle, "Open at login")
                }
            }
            .background(card)
            .animation(NotchStyle.snappy, value: tm.isModelInstalled)

            if upgrader {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your 2.x library is safe.").font(.system(size: 14, weight: .medium))
                    Text("Nothing was deleted. Meetings, dictation and summaries are retired, so MindExtract now does one thing: video and audio in, text out.")
                        .font(NotchStyle.small)
                        .foregroundStyle(NotchStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ChipButton(icon: "folder", title: String(localized: "Show My Old Recordings")) {
                        let folder = TranscriptionHistoryManager.recordingsFolder
                        if FileManager.default.fileExists(atPath: folder.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        } else {
                            NSWorkspace.shared.open(URL(fileURLWithPath: AppSettings.shared.downloadPath))
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(card)
            }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08)))
    }

    private func row<Control: View>(title: LocalizedStringKey, detail: LocalizedStringKey,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(NotchStyle.small).foregroundStyle(NotchStyle.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

// MARK: - Pager

/// One thin segment per step; the done ones are white.
private struct Pager: View {
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<Onboarding.pagerCount, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? NotchStyle.text : Color.white.opacity(0.18))
                    .frame(width: i == index ? 28 : 16, height: 2)
            }
        }
        .animation(NotchStyle.snappy, value: index)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Step \(index + 1) of \(Onboarding.pagerCount)"))
    }
}

// MARK: - The caption under the closed notch

struct OnboardingCaption: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
            Text(verbatim: text).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(NotchStyle.text)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Text that sharpens in

/// Glyphs arrive one after another, from a soft blur and a few points low.
struct RevealRenderer: TextRenderer {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run.map { $0 } } }
        let count = max(slices.count, 1)
        let spread = 0.65   // how much of the animation the stagger takes
        for (i, slice) in slices.enumerated() {
            let start = Double(i) / Double(count) * spread
            let t = min(max((progress - start) / (1 - spread), 0), 1)
            var copy = context
            copy.opacity = t
            if t < 1 {
                copy.addFilter(.blur(radius: (1 - t) * 5))
                copy.translateBy(x: 0, y: (1 - t) * 5)
            }
            copy.draw(slice)
        }
    }
}

struct RevealText: View {
    let text: String
    let font: Font
    var color: Color = NotchStyle.text
    var tracking: CGFloat = 0
    var alignment: TextAlignment = .center
    var delay: Double = 0
    var duration: Double = 0.6
    @State private var progress: Double = NotchStyle.reduceMotion ? 1 : 0

    init(_ text: String, font: Font, color: Color = NotchStyle.text, tracking: CGFloat = 0,
         alignment: TextAlignment = .center, delay: Double = 0, duration: Double = 0.6) {
        self.text = text
        self.font = font
        self.color = color
        self.tracking = tracking
        self.alignment = alignment
        self.delay = delay
        self.duration = duration
    }

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(RevealRenderer(progress: progress))
            .onAppear {
                guard progress < 1 else { return }
                withAnimation(.easeOut(duration: duration).delay(delay)) { progress = 1 }
            }
    }
}

// MARK: - The hero: one object that changes shape

private struct HeroStage: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var tm = TranscriptionManager.shared
    let beat: Onboarding.Beat

    // Welcome choreography
    @State private var traced: CGFloat = NotchStyle.reduceMotion ? 1 : 0
    @State private var cursorIn = false
    @State private var swell = false
    @State private var keysDown = false
    // Try it: a link typing itself
    @State private var typed = ""
    // Paste: the ⌘V keys
    @State private var pastePress = false

    struct Form {
        var size: CGSize
        var top: CGFloat
        var bottom: CGFloat
        var y: CGFloat
    }

    private var form: Form {
        switch beat {
        case .welcome, .summon:
            return Form(size: CGSize(width: 200, height: 44), top: 0, bottom: 18, y: -46)
        case .tryIt:
            return Form(size: CGSize(width: 380, height: 48), top: 24, bottom: 24, y: 0)
        case .paste:
            return Form(size: CGSize(width: 220, height: 46), top: 23, bottom: 23, y: -18)
        case .finish:
            return Form(size: CGSize(width: 150, height: 38), top: 0, bottom: 16, y: -30)
        }
    }

    var body: some View {
        let f = form
        let shape = UnevenRoundedRectangle(topLeadingRadius: f.top, bottomLeadingRadius: f.bottom,
                                           bottomTrailingRadius: f.bottom, topTrailingRadius: f.top,
                                           style: .continuous)
        ZStack {
            // Light, not a box.
            RadialGradient(colors: [Color.white.opacity(swell ? 0.11 : 0.07), .clear],
                           center: .center, startRadius: 0, endRadius: 230)

            // The top edge of the screen, for the steps where the object is a notch.
            if hangsFromEdge {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.22), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 380, height: 1)
                    .offset(y: f.y - f.size.height / 2)
                    .transition(.opacity)
            }

            ZStack {
                shape.fill(objectFill)
                shape.stroke(Color.white.opacity(0.14), lineWidth: 1)
                // Progress or the welcome trace: the object's own outline fills in white.
                if let outline = outlineProgress {
                    shape.trim(from: 0, to: max(0.001, outline))
                        .stroke(NotchStyle.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .animation(.easeOut(duration: 0.4), value: outline)
                }
                inside
                    .transition(NotchStyle.swap)
                    .id(insideKey)
            }
            .frame(width: f.size.width, height: f.size.height)
            .scaleEffect(swell ? 1.06 : 1, anchor: .top)
            .offset(y: f.y)

            // The pointer and the keys, around the welcome notch.
            if beat == .welcome || beat == .summon {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(NotchStyle.text)
                    .shadow(color: .black, radius: 2)
                    .offset(x: cursorIn ? 16 : 150, y: cursorIn ? f.y + 8 : 58)
                    .opacity(cursorIn ? 1 : 0)
                KeyCombo(keys: hotKeyCaps, pressed: keysDown)
                    .offset(y: 46)
            }
            if beat == .paste {
                KeyCombo(keys: ["⌘", "V"], pressed: pastePress || model.onboardingPaste != nil)
                    .offset(y: 30)
                    .opacity(model.onboardingPaste == nil ? 1 : 0.35)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: beat)
        .task(id: beat) { await choreograph() }
    }

    private var hangsFromEdge: Bool { beat == .welcome || beat == .summon || beat == .finish }

    private var objectFill: Color {
        switch beat {
        case .tryIt, .paste: return Color.white.opacity(0.07)
        default: return Color.black
        }
    }

    /// White outline progress: the welcome trace, or a download.
    private var outlineProgress: CGFloat? {
        switch beat {
        case .welcome, .summon:
            return traced < 1 ? traced : nil
        case .tryIt:
            if case .working(_, _, _, let p?) = model.stage { return CGFloat(p) }
            return nil
        case .finish:
            return tm.isDownloadingModel ? CGFloat(tm.modelDownloadProgress) : nil
        case .paste:
            return nil
        }
    }

    private var insideKey: String {
        switch beat {
        case .tryIt:
            switch model.stage {
            case .working, .loadingInfo: return "working"
            case .failed: return "failed"
            default: return model.clipboardLink == nil ? "typing" : "link"
            }
        default: return "\(beat.rawValue)"
        }
    }

    @ViewBuilder private var inside: some View {
        switch beat {
        case .welcome, .summon:
            EmptyView()
        case .tryIt:
            HStack(spacing: 10) {
                switch model.stage {
                case .working(_, _, let phase, let p):
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: !NotchStyle.reduceMotion)
                    Text(verbatim: phase).lineLimit(1)
                    Spacer(minLength: 4)
                    if let p { Text(p, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                case .loadingInfo:
                    ProgressRing(progress: nil).frame(width: 14, height: 14)
                    Text(verbatim: model.input).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                    Text("Not this time").foregroundStyle(NotchStyle.secondary)
                    Spacer(minLength: 0)
                default:
                    Image(systemName: "link").foregroundStyle(NotchStyle.secondary)
                    if let link = model.clipboardLink {
                        Text(verbatim: Self.short(link)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark")
                    } else {
                        Text(verbatim: typed).foregroundStyle(NotchStyle.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(NotchStyle.text)
            .padding(.horizontal, 18)
        case .paste:
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                Text("Copied").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(NotchStyle.text)
        case .finish:
            Image(systemName: tm.isModelInstalled ? "checkmark" : "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NotchStyle.text)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var hotKeyCaps: [String] {
        guard let combo = GlobalHotKey.shared.combo else { return [] }
        var caps: [String] = []
        if combo.modifiers.contains(.control) { caps.append("⌃") }
        if combo.modifiers.contains(.option) { caps.append("⌥") }
        if combo.modifiers.contains(.shift) { caps.append("⇧") }
        if combo.modifiers.contains(.command) { caps.append("⌘") }
        caps.append(combo.keyName == "Space" ? String(localized: "Space") : combo.keyName)
        return caps
    }

    /// "youtube.com/watch?v=abc" from a full link.
    static func short(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host() else { return link }
        let path = url.path() + (url.query().map { "?" + $0 } ?? "")
        return host.replacingOccurrences(of: "www.", with: "") + path
    }

    // MARK: Motion

    @MainActor
    private func choreograph() async {
        let still = NotchStyle.reduceMotion
        switch beat {
        case .welcome:
            if traced < 1 {
                withAnimation(.easeInOut(duration: 1.3)) { traced = 1 }
                try? await Task.sleep(for: .seconds(1.4))
            }
            guard !still else { return }
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.86)) { cursorIn = true }
                try? await Task.sleep(for: .seconds(0.95))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { swell = true }
                try? await Task.sleep(for: .seconds(0.7))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { swell = false; cursorIn = false }
                try? await Task.sleep(for: .seconds(0.9))
                // The other way in: the shortcut.
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { keysDown = true }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.05)) { swell = true }
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { keysDown = false; swell = false }
                try? await Task.sleep(for: .seconds(2.2))
            }
        case .tryIt:
            let demo = "youtube.com/watch?v=…"
            guard !still else { typed = demo; return }
            while !Task.isCancelled {
                for ch in demo {
                    typed.append(ch)
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 28...60)))
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .seconds(1.8))
                typed = ""
                try? await Task.sleep(for: .seconds(0.5))
            }
        case .paste:
            guard !still else { return }
            while !Task.isCancelled, model.onboardingPaste == nil {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) { pastePress = true }
                try? await Task.sleep(for: .seconds(0.25))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pastePress = false }
            }
        default:
            break
        }
    }
}

/// Keycaps that sink a little when pressed.
private struct KeyCombo: View {
    let keys: [String]
    let pressed: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(verbatim: key)
                    .font(.system(size: key.count > 1 ? 12 : 14, weight: .semibold))
                    .padding(.horizontal, key.count > 1 ? 12 : 0)
                    .frame(minWidth: 30, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(pressed ? 0.20 : 0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18)))
                    .shadow(color: .black.opacity(pressed ? 0 : 0.5), radius: 0, y: pressed ? 0 : 2)
                    .offset(y: pressed ? 1.5 : 0)
                    .scaleEffect(pressed ? 0.95 : 1)
            }
        }
        .foregroundStyle(NotchStyle.text)
    }
}
