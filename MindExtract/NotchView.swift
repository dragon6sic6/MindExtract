import SwiftUI
import UniformTypeIdentifiers

// MARK: - Look
//
// Black and white only. Emphasis comes from fill, weight and opacity; there is
// one solid-white control per screen — the thing you most likely want next.

enum NotchStyle {
    static let surface = Color.black
    // Text
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.64)
    static let tertiary = Color.white.opacity(0.56)
    static let disabled = Color.white.opacity(0.30)
    // Fills (white over black, so they also work over thumbnails)
    static let field = Color.white.opacity(0.08)
    static let fieldHover = Color.white.opacity(0.12)
    static let fieldPressed = Color.white.opacity(0.16)
    static let stroke = Color.white.opacity(0.10)
    static let focus = Color.white.opacity(0.40)
    static let primary = Color.white
    static let onPrimary = Color.black

    // Shapes
    static let radiusSmall: CGFloat = 8
    static let radius: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let shellBottom: CGFloat = 28
    static let controlHeight: CGFloat = 36
    static let mainHeight: CGFloat = 40
    static let chipHeight: CGFloat = 28
    static let rowHeight: CGFloat = 32
    static let side: CGFloat = 20

    // Type
    static let title = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let control = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .medium)
    static let small = Font.system(size: 12)

    // Motion — springs, or a short fade when Reduce Motion is on.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var openAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.8) }
    static var closeAnimation: Animation { reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 1.0) }
    static var snappy: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85) }
}

/// The notch silhouette: flush with the top edge, concave shoulders that melt
/// into the bezel, continuous rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = top
        let b = max(0, min(bottom, r.height / 2, (r.width - 2 * t) / 2))
        let k: CGFloat = 0.55   // cubic handles: smooth, not pinched
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + t, y: r.minY + t),
                   control1: CGPoint(x: r.minX + t * k, y: r.minY),
                   control2: CGPoint(x: r.minX + t, y: r.minY + t * (1 - k)))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY),
                   control1: CGPoint(x: r.minX + t, y: r.maxY - b * (1 - k)),
                   control2: CGPoint(x: r.minX + t + b * (1 - k), y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - t - b * (1 - k), y: r.maxY),
                   control2: CGPoint(x: r.maxX - t, y: r.maxY - b * (1 - k)))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY),
                   control1: CGPoint(x: r.maxX - t, y: r.minY + t * (1 - k)),
                   control2: CGPoint(x: r.maxX - t * k, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            NotchSurface()
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

struct NotchSurface: View {
    @EnvironmentObject var model: NotchModel
    @State private var dropHover = false
    @State private var popped = false

    private var g: NotchGeometry { model.geometry }
    private var wingWidth: CGFloat {
        if model.isBusy || (model.hasUnseenResult && !model.unseenIsQuiet) { return NotchMetrics.activitySide }
        return model.hasUnseenResult ? NotchMetrics.quietSide : 0
    }
    private var showsActivity: Bool { !model.isOpen && wingWidth > 0 }
    private var topRadius: CGFloat { model.isOpen ? 14 : 6 }
    private var bottomRadius: CGFloat {
        model.isOpen ? NotchStyle.shellBottom : (showsActivity ? 14 : min(12, g.notchSize.height * 0.35))
    }
    /// Without a hardware notch there is nothing to cover while idle.
    private var invisible: Bool { !g.hasNotch && !model.isOpen && !showsActivity }

    var body: some View {
        let shape = NotchShape(top: topRadius, bottom: bottomRadius)
        ZStack(alignment: .top) {
            if model.isOpen {
                OpenNotch(dropHover: dropHover)
                    .frame(width: NotchMetrics.openWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: OpenSizeKey.self, value: proxy.size)
                    })
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: NotchStyle.reduceMotion ? 1 : 0.96, anchor: .top))
                            .animation(NotchStyle.openAnimation.delay(0.05)),
                        removal: .identity))
            } else if showsActivity {
                ActivityNotch(quiet: model.unseenIsQuiet && !model.isBusy)
                    .frame(width: g.notchSize.width + 2 * wingWidth, height: g.notchSize.height)
                    .transition(.opacity)
            } else {
                Color.clear.frame(width: g.notchSize.width, height: g.notchSize.height)
            }
        }
        .padding(.horizontal, topRadius)
        .background(shape.fill(NotchStyle.surface))
        .overlay {
            // A hairline rim so black still has an edge on a dark wallpaper —
            // faded out where the shape meets the top of the screen.
            shape.stroke(Color.white.opacity(model.isOpen ? 0.09 : 0), lineWidth: 1)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(model.isOpen ? 0.35 : 0), radius: 24, y: 10)
        .opacity(invisible ? 0 : 1)
        .scaleEffect(popped ? 1.08 : 1, anchor: .top)
        .onPreferenceChange(OpenSizeKey.self) { size in model.openSize = size }
        .onDrop(of: [.fileURL, .url], isTargeted: $dropHover) { providers in handleDrop(providers) }
        .animation(model.isOpen ? NotchStyle.openAnimation : NotchStyle.closeAnimation, value: model.isOpen)
        .animation(NotchStyle.snappy, value: wingWidth)
        .animation(NotchStyle.snappy, value: model.stage.screen)
        .animation(NotchStyle.snappy, value: model.dragKind)
        .onChange(of: model.popCount) { _, _ in
            guard !NotchStyle.reduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { popped = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { popped = false }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy, let provider = providers.first else { return false }   // Finder animates it back
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let model = NotchModel.shared
                    model.dragKind = nil
                    model.useFile(url)
                    model.transcribe()   // a file can only be transcribed — start right away
                    NotchController.shared.open(.drag)
                }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                let model = NotchModel.shared
                model.dragKind = nil
                model.input = url.absoluteString
                model.submit()
                NotchController.shared.open(.drag)
            }
        }
        return true
    }
}

private struct OpenSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Closed, with something going on

struct ActivityNotch: View {
    @EnvironmentObject var model: NotchModel
    let quiet: Bool

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: quiet ? NotchMetrics.quietSide : NotchMetrics.activitySide)
            Spacer(minLength: 0)
            trailing.frame(width: quiet ? NotchMetrics.quietSide : NotchMetrics.activitySide)
        }
        .padding(.horizontal, 2)
        .foregroundStyle(NotchStyle.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder private var leading: some View {
        if quiet {
            Circle().fill(NotchStyle.text).frame(width: 5, height: 5)
        } else {
            switch model.stage {
            case .working, .loadingInfo:
                ProgressRing(progress: model.activityProgress).frame(width: 14, height: 14)
            case .transcribed, .downloaded:
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if !quiet {
            switch model.stage {
            case .working(_, let work, _, let p):
                if let p {
                    Text(p, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                } else if work == .transcribe {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchStyle.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: !NotchStyle.reduceMotion)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchStyle.secondary)
                }
            case .transcribed, .downloaded:
                Text("Done").font(.system(size: 12, weight: .semibold))
            default:
                EmptyView()
            }
        }
    }

    private var accessibilitySummary: String {
        switch model.stage {
        case .working(_, _, let phase, let p):
            return p.map { "\(phase) \(Int($0 * 100)) %" } ?? phase
        case .transcribed: return String(localized: "Transcript ready")
        case .downloaded: return String(localized: "Saved")
        case .failed: return String(localized: "Something went wrong")
        default: return "MindExtract"
        }
    }
}

struct ProgressRing: View {
    let progress: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(NotchStyle.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(NotchStyle.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        guard !NotchStyle.reduceMotion else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Open

struct OpenNotch: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var tm = TranscriptionManager.shared
    let dropHover: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                if let kind = model.dragKind {
                    DropZone(kind: kind, busy: model.isBusy, highlighted: dropHover)
                } else {
                    content
                }
                if let downloading = tm.downloadingModel, !model.isBusy {
                    ModelDownloadLine(name: downloading.displayName, progress: tm.modelDownloadProgress)
                }
            }
            .padding(.horizontal, NotchStyle.side)
            .padding(.top, 4)
            .padding(.bottom, NotchStyle.side)
        }
        .foregroundStyle(NotchStyle.text)
    }

    /// Beside the hardware notch: the name on the left, the menu on the right.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold))
                Text(verbatim: "MindExtract").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.5))
            .accessibilityHidden(true)
            Spacer(minLength: model.geometry.notchSize.width + 24)
            NotchMenu()
        }
        .padding(.leading, NotchStyle.side)
        .padding(.trailing, NotchStyle.side - 6)
        .frame(height: max(32, model.geometry.notchSize.height))
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .idle:
            if model.clipboardLink != nil { CopiedLinkCard() }
            LinkField()
            RecentList()
        case .loadingInfo:
            LinkField()
            ItemCard(item: nil)
            HStack {
                Spacer()
                ChipButton(icon: "xmark", title: String(localized: "Cancel")) { model.cancel() }
            }
        case .ready(let item):
            ItemCard(item: item)
            ReadyActions(item: item)
        case .working(let item, _, let phase, let progress):
            ItemCard(item: item, dimmed: true)
            WorkingRow(phase: phase, progress: progress)
        case .transcribed(let item, let path):
            ItemCard(item: item, done: true)
            TranscribedActions(item: item, path: path)
        case .downloaded(let item, let path):
            ItemCard(item: item, done: true)
            DownloadedActions(path: path)
        case .failed(let item, let work, let message, let problem, let url):
            if let item { ItemCard(item: item) }
            FailedCard(message: message, problem: problem, canRetry: item != nil || url != nil, work: work)
        }
    }
}

// MARK: - Pieces

/// The copied link, ready in one click.
struct CopiedLinkCard: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 11, weight: .semibold))
                Text("Copied link")
                Text(verbatim: LinkField.shortLink(model.clipboardLink ?? ""))
                    .foregroundStyle(NotchStyle.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(NotchStyle.caption)
            .foregroundStyle(NotchStyle.secondary)
            HStack(spacing: 8) {
                Button { model.transcribeCopiedLink() } label: {
                    Label("Transcribe", systemImage: "text.quote")
                }
                .buttonStyle(NotchButtonStyle(kind: .primary, expand: true, height: NotchStyle.mainHeight))
                .keyboardShortcut(.defaultAction)
                Button { model.saveCopiedLink() } label: {
                    Label("Save Video", systemImage: "arrow.down")
                }
                .buttonStyle(NotchButtonStyle(kind: .secondary, height: NotchStyle.mainHeight))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous).fill(Color.white.opacity(0.06)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct LinkField: View {
    @EnvironmentObject var model: NotchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if case .loadingInfo = model.stage {
                ProgressRing(progress: nil).frame(width: 14, height: 14)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            TextField("", text: $model.input,
                      prompt: Text("Paste a link or drag a file here").foregroundStyle(NotchStyle.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { model.submit() }
                .disabled(model.isBusy)
                .accessibilityLabel("Link")
            if !model.input.isEmpty, !model.isBusy {
                Button { model.submit() } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NotchStyle.onPrimary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(NotchStyle.primary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fetch")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotchStyle.mainHeight)
        .background(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous).fill(NotchStyle.field))
        .overlay(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous)
            .strokeBorder(focused ? NotchStyle.focus : .clear))
        .animation(NotchStyle.snappy, value: model.input.isEmpty)
        .onChange(of: focused) { _, f in model.isEditing = f }
        .onChange(of: model.focusCount) { _, _ in focused = true }
        .onAppear { if model.focusCount > 0, model.clipboardLink == nil { focused = true } }
    }

    static func shortLink(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else { return link }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h + url.path + (url.query.map { "?" + $0 } ?? "")
    }
}

struct ItemCard: View {
    let item: NotchModel.Item?
    var dimmed = false
    var done = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 104, height: 58)
                .opacity(dimmed ? 0.6 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(NotchStyle.stroke, lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) {
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NotchStyle.onPrimary, NotchStyle.primary)
                            .padding(4)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let item {
                    Text(verbatim: item.title)
                        .font(NotchStyle.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.subtitle.isEmpty {
                        Text(verbatim: item.subtitle)
                            .font(NotchStyle.small)
                            .foregroundStyle(NotchStyle.secondary)
                            .lineLimit(1)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(NotchStyle.field).frame(width: 240, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(NotchStyle.field).frame(width: 140, height: 12)
                }
            }
            .opacity(item == nil ? (pulse ? 1 : 0.5) : 1)
            Spacer(minLength: 0)
        }
        .animation(NotchStyle.snappy, value: done)
        .onAppear {
            guard item == nil, !NotchStyle.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = item?.thumbnail {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder(icon: "play.rectangle")
                }
            }
        } else {
            placeholder(icon: item?.filePath != nil ? "film" : "play.rectangle")
        }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            NotchStyle.field
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(NotchStyle.tertiary)
        }
    }
}

struct ReadyActions: View {
    @EnvironmentObject var model: NotchModel
    let item: NotchModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if item.url != nil {
                    Button { model.download() } label: {
                        Label(model.audioOnly ? "Save Audio" : "Save Video", systemImage: "arrow.down")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .secondary))
                }
                Button { model.transcribe() } label: {
                    Label("Transcribe", systemImage: "text.quote")
                }
                .buttonStyle(NotchButtonStyle(kind: .primary, expand: true))
                .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 2) {
                Menu {
                    Picker("Spoken language", selection: $model.language) {
                        ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                            Text(verbatim: lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ChipLabel(icon: "globe", title: String(localized: "Language: \(languageName)"))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if item.url != nil {
                    Menu {
                        Picker("Save as", selection: $model.audioOnly) {
                            Text("Video").tag(false)
                            Text("Audio only").tag(true)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        ChipLabel(icon: model.audioOnly ? "waveform" : "film",
                                  title: model.audioOnly ? String(localized: "Save: Audio only") : String(localized: "Save: Video"))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Spacer()
                ChipButton(icon: "plus", title: String(localized: "New Link")) { model.clear() }
            }
        }
    }

    private var languageName: String {
        AppSettings.transcriptionLanguages.first { $0.code == model.language }?.name ?? model.language
    }
}

struct WorkingRow: View {
    @EnvironmentObject var model: NotchModel
    let phase: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressBar(progress: progress)
            HStack(spacing: 4) {
                Text(verbatim: phase)
                    .foregroundStyle(NotchStyle.secondary)
                if let progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(NotchStyle.text)
                }
                Spacer()
                ChipButton(icon: "xmark", title: String(localized: "Cancel")) { model.cancel() }
            }
            .font(NotchStyle.caption)
        }
    }
}

struct ProgressBar: View {
    let progress: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                if let progress {
                    Capsule()
                        .fill(NotchStyle.primary)
                        .frame(width: max(4, proxy.size.width * min(1, progress)))
                        .animation(.easeOut(duration: 0.35), value: progress)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, NotchStyle.primary, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * 0.35)
                        .offset(x: sweep ? proxy.size.width * 0.65 : 0)
                        .onAppear {
                            guard !NotchStyle.reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) %" } ?? String(localized: "In progress"))
    }
}

struct TranscribedActions: View {
    @EnvironmentObject var model: NotchModel
    let item: NotchModel.Item
    let path: String
    @State private var preview: String?
    @State private var words = 0
    @State private var refresh = 0   // re-reads whether our copy is still on the clipboard

    var body: some View {
        let copied = { _ = refresh; return model.isOnClipboard(path) }()
        let assistant = Assistant.preferred
        VStack(alignment: .leading, spacing: 10) {
            if let preview {
                Text(verbatim: preview)
                    .font(NotchStyle.small)
                    .foregroundStyle(NotchStyle.secondary)
                    .lineLimit(3)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous).fill(NotchStyle.field))
                    .overlay(alignment: .bottomTrailing) {
                        if words > 0 {
                            Text("≈ \(words) words")
                                .font(NotchStyle.small)
                                .foregroundStyle(NotchStyle.tertiary)
                                .padding(8)
                        }
                    }
            }
            HStack(spacing: 8) {
                Button {
                    model.copyTranscript(path: path, item: item)
                    refresh += 1
                } label: {
                    Label(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(NotchButtonStyle(kind: copied ? .done : .primary, expand: true, height: NotchStyle.mainHeight))
                .keyboardShortcut("c", modifiers: .command)
                if assistant != .none {
                    Button {
                        if !copied { model.copyTranscript(path: path, item: item) }
                        assistant.open()
                        NotchController.shared.closeAfterHandOff()
                    } label: {
                        Text("Open \(assistant.name)")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .secondary, height: NotchStyle.mainHeight))
                    .help("Copies the transcript and opens \(assistant.name) — paste with ⌘V")
                }
                Menu {
                    Button("Copy with Timestamps") {
                        model.copyTranscript(path: path, item: item, timestamps: true)
                        refresh += 1
                    }
                    Divider()
                    Button("Open Transcript") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        NotchController.shared.closeAfterHandOff()
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        NotchController.shared.closeAfterHandOff()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NotchStyle.text)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More Options")
                .modifier(SquareBackground(size: NotchStyle.mainHeight, filled: true))
                Button { model.clear() } label: { SquareIcon(name: "plus") }
                    .buttonStyle(.plain)
                    .help("New link")
                    .accessibilityLabel("New Link")
            }
            if copied {
                Text(model.autoCopiedPath == path ? "Copied automatically — paste with ⌘V in Claude, ChatGPT or anywhere."
                                                  : "Paste with ⌘V in Claude, ChatGPT or anywhere.")
                    .font(NotchStyle.small)
                    .foregroundStyle(NotchStyle.tertiary)
                    .transition(.opacity)
            }
        }
        .animation(NotchStyle.snappy, value: copied)
        .onAppear(perform: load)
        .onChange(of: path) { _, _ in load() }
    }

    private func load() {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { preview = nil; return }
        let text = TranscriptCopy.plain(raw)
        preview = text.isEmpty ? nil : String(text.prefix(600))
        words = text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

struct DownloadedActions: View {
    @EnvironmentObject var model: NotchModel
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                NotchController.shared.closeAfterHandOff()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(NotchButtonStyle(kind: .secondary, height: NotchStyle.mainHeight))
            Button { model.transcribe() } label: {
                Label("Transcribe", systemImage: "text.quote")
            }
            .buttonStyle(NotchButtonStyle(kind: .primary, expand: true, height: NotchStyle.mainHeight))
            .keyboardShortcut(.defaultAction)
            Button { model.clear() } label: { SquareIcon(name: "plus") }
                .buttonStyle(.plain)
                .help("New link")
                .accessibilityLabel("New Link")
        }
    }
}

struct FailedCard: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var tm = TranscriptionManager.shared
    let message: String
    let problem: NotchModel.Problem
    let canRetry: Bool
    let work: NotchModel.Work?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(problem == .general ? "That didn't work" : "One more step")
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: message)
                        .font(NotchStyle.small)
                        .foregroundStyle(NotchStyle.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                switch problem {
                case .needsSpeechModel:
                    Button { model.downloadModelAndContinue() } label: {
                        Label("Download and Transcribe", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
                    .disabled(tm.downloadingModel != nil)
                case .needsSignIn:
                    Button { model.signInToYouTube() } label: {
                        Label("Sign In to YouTube", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
                case .general:
                    if canRetry {
                        Button { model.retry() } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(NotchButtonStyle(kind: .primary))
                    }
                }
                Spacer()
                ChipButton(icon: "plus", title: String(localized: "New Link")) { model.clear() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

struct ModelDownloadLine: View {
    let name: String
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            ProgressRing(progress: progress > 0 ? progress : nil).frame(width: 13, height: 13)
            Text("Downloading \(name)…")
                .foregroundStyle(NotchStyle.secondary)
            Spacer()
            if progress > 0 {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(NotchStyle.secondary)
            }
        }
        .font(NotchStyle.small)
    }
}

struct DropZone: View {
    let kind: NotchModel.DragKind
    let busy: Bool
    let highlighted: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: busy ? "hourglass" : (kind == .file ? "arrow.down.doc" : "link"))
                .font(.system(size: 24, weight: .regular))
                .scaleEffect(appeared ? 1 : 0.8)
            Text(busy ? "Finish or cancel the current one first" : (kind == .file ? "Drop to transcribe" : "Drop the link"))
                .font(NotchStyle.title)
            if !busy {
                Text(kind == .file ? "Video or audio, any format" : "Any site that plays video")
                    .font(NotchStyle.small)
                    .foregroundStyle(NotchStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous)
            .fill(Color.white.opacity(highlighted ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: NotchStyle.radiusLarge, style: .continuous)
            .strokeBorder(Color.white.opacity(highlighted ? 0.6 : 0.30), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .animation(NotchStyle.snappy, value: highlighted)
        .onAppear { withAnimation(NotchStyle.snappy) { appeared = true } }
    }
}

struct RecentList: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var transcripts = TranscriptionHistoryManager.shared
    @ObservedObject private var downloads = HistoryManager.shared

    var body: some View {
        let entries = RecentEntry.latest(4)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                ForEach(entries) { RecentRow(entry: $0) }
            }
        }
    }
}

struct RecentRow: View {
    @EnvironmentObject var model: NotchModel
    let entry: RecentEntry
    @State private var hovering = false
    @State private var refresh = 0

    var body: some View {
        let copied = { _ = refresh; return entry.path.map(model.isOnClipboard) ?? false }()
        Button(action: primary) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: entry.kind == .transcript ? "doc.text" : "film")
                    if entry.alsoDownloaded { Image(systemName: "film").opacity(0.7) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchStyle.secondary)
                .frame(width: entry.alsoDownloaded ? 30 : 16, alignment: .leading)
                Text(verbatim: entry.title)
                    .font(NotchStyle.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                    } else if hovering {
                        Text(entry.kind == .transcript ? "Copy" : "Open")
                    } else {
                        Text(entry.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .foregroundStyle(NotchStyle.tertiary)
                    }
                }
                .font(.system(size: 12, weight: hovering || copied ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .frame(height: NotchStyle.rowHeight)
            .background(RoundedRectangle(cornerRadius: NotchStyle.radiusSmall, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if entry.kind == .transcript, let path = entry.path {
                Button("Copy with Timestamps") {
                    model.copyTranscript(path: path, item: item, timestamps: true)
                    refresh += 1
                }
            }
            Button("Open") { model.openRecent(entry) }
            if let path = entry.path {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    NotchController.shared.closeAfterHandOff()
                }
            }
        }
        .accessibilityLabel(entry.kind == .transcript ? String(localized: "Transcript, \(entry.title)")
                                                      : String(localized: "Saved video, \(entry.title)"))
        .accessibilityHint(entry.kind == .transcript ? String(localized: "Copies the transcript") : String(localized: "Opens it"))
    }

    private var item: NotchModel.Item { NotchModel.Item(title: entry.title, url: entry.url, filePath: entry.path) }

    private func primary() {
        guard let path = entry.path else { return }
        switch entry.kind {
        case .transcript:
            model.copyTranscript(path: path, item: item)
            refresh += 1
        case .download:
            model.openRecent(entry)
        }
    }
}

struct NotchMenu: View {
    var body: some View {
        Menu {
            Button("Settings…") { SettingsWindow.show() }
            Button("Show Saved Files") {
                NSWorkspace.shared.open(URL(fileURLWithPath: AppSettings.shared.downloadPath))
                NotchController.shared.closeAfterHandOff()
            }
            Divider()
            Button("Quit MindExtract") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchStyle.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .modifier(SquareBackground(size: 28, filled: false))
    }
}

// MARK: - Controls

/// Secondary text actions: a 28 pt chip with a hover fill.
struct ChipButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { ChipLabel(icon: icon, title: title) }
            .buttonStyle(.plain)
    }
}

struct ChipLabel: View {
    let icon: String
    let title: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(verbatim: title).font(NotchStyle.small)
        }
        .foregroundStyle(hovering ? NotchStyle.text : NotchStyle.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: NotchStyle.chipHeight)
        .background(RoundedRectangle(cornerRadius: NotchStyle.radiusSmall, style: .continuous)
            .fill(hovering ? Color.white.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// A 40 × 40 icon square next to the main button.
struct SquareIcon: View {
    let name: String

    var body: some View {
        HoverSquare(size: NotchStyle.mainHeight, filled: true) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NotchStyle.text)
        }
    }
}

/// The same square, drawn around a control that draws its own label (menus
/// drop a label's background).
struct SquareBackground: ViewModifier {
    var size: CGFloat
    var filled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: filled ? NotchStyle.radius : NotchStyle.radiusSmall, style: .continuous)
                .fill(hovering ? NotchStyle.fieldHover : (filled ? NotchStyle.field : .clear)))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

struct HoverSquare<Content: View>: View {
    var size: CGFloat
    var filled = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: filled ? NotchStyle.radius : NotchStyle.radiusSmall, style: .continuous)
                .fill(hovering ? NotchStyle.fieldHover : (filled ? NotchStyle.field : .clear)))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

struct NotchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, done }
    var kind: Kind
    var expand = false
    var height: CGFloat = NotchStyle.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(configuration: configuration, kind: kind, expand: expand, height: height)
    }
}

/// A view (not the style itself) so hover state can live in @State.
private struct NotchButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: NotchButtonStyle.Kind
    let expand: Bool
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(NotchStyle.control)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: NotchStyle.radius, style: .continuous).fill(fill))
            .scaleEffect(configuration.isPressed && !NotchStyle.reduceMotion ? 0.97 : 1)
            .animation(NotchStyle.snappy, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        guard isEnabled else { return NotchStyle.disabled }
        return kind == .primary ? NotchStyle.onPrimary : NotchStyle.text
    }

    private var fill: Color {
        guard isEnabled else { return Color.white.opacity(0.10) }
        switch kind {
        case .primary: return NotchStyle.primary.opacity(configuration.isPressed ? 0.8 : (hovering ? 0.9 : 1))
        case .secondary: return configuration.isPressed ? NotchStyle.fieldPressed : (hovering ? NotchStyle.fieldHover : NotchStyle.field)
        case .done: return Color.white.opacity(0.14)   // the monochrome "it worked"
        }
    }
}
