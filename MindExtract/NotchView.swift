import SwiftUI
import UniformTypeIdentifiers

// MARK: - Look

enum NotchStyle {
    static let surface = Color.black
    static let field = Color(white: 0.115)
    static let fieldHover = Color(white: 0.15)
    static let stroke = Color(white: 0.2)
    static let text = Color(white: 0.96)
    static let secondary = Color(white: 0.62)
    static let tertiary = Color(white: 0.42)
    /// Black and white only: the accent is white, emphasis comes from weight and fill.
    static let accent = Color.white
    static let warning = Color(white: 0.96)

    static let open = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.85)
}

/// The notch silhouette: flush with the top edge, concave shoulders that melt
/// into the bezel, rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let b = max(0, min(bottom, r.height / 2, (r.width - 2 * top) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + b, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - b), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
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

    private var g: NotchGeometry { model.geometry }
    private var showsActivity: Bool { !model.isOpen && (model.isBusy || model.hasUnseenResult) }
    private var topRadius: CGFloat { model.isOpen ? 14 : 6 }
    private var bottomRadius: CGFloat { model.isOpen ? 26 : (showsActivity ? 14 : min(12, g.notchSize.height * 0.35)) }

    var body: some View {
        ZStack(alignment: .top) {
            if model.isOpen {
                OpenNotch()
                    .frame(width: NotchMetrics.openWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: OpenSizeKey.self, value: proxy.size)
                    })
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(NotchStyle.open.delay(0.05)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else if showsActivity {
                ActivityNotch()
                    .frame(width: g.notchSize.width + 2 * NotchMetrics.activitySide, height: g.notchSize.height)
                    .transition(.opacity)
            } else {
                Color.clear.frame(width: g.notchSize.width, height: g.notchSize.height)
            }
        }
        .padding(.horizontal, topRadius)
        .background(NotchShape(top: topRadius, bottom: bottomRadius).fill(NotchStyle.surface))
        .clipShape(NotchShape(top: topRadius, bottom: bottomRadius))
        .shadow(color: .black.opacity(model.isOpen ? 0.45 : 0), radius: 18, y: 8)
        .scaleEffect(model.isDropTargeted && !model.isOpen ? 1.06 : 1, anchor: .top)
        .onPreferenceChange(OpenSizeKey.self) { size in model.openSize = size }
        .onDrop(of: [.fileURL, .url], isTargeted: Binding(get: { model.isDropTargeted },
                                                         set: { model.isDropTargeted = $0 })) { providers in
            handleDrop(providers)
        }
        .onTapGesture { if !model.isOpen { NotchController.shared.open() } }
        .animation(NotchStyle.open, value: model.isOpen)
        .animation(NotchStyle.snappy, value: showsActivity)
        .animation(NotchStyle.snappy, value: model.isDropTargeted)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let model = NotchModel.shared
                    model.useFile(url)
                    model.transcribe()   // a file can only be transcribed — start right away
                    NotchController.shared.open(sticky: true)
                }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                let model = NotchModel.shared
                model.input = url.absoluteString
                model.submit()
                NotchController.shared.open(sticky: true)
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

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: NotchMetrics.activitySide)
            Spacer(minLength: 0)
            trailing
                .frame(width: NotchMetrics.activitySide)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var leading: some View {
        switch model.stage {
        case .working, .loadingInfo:
            ProgressRing(progress: model.activityProgress)
                .frame(width: 15, height: 15)
        case .transcribed, .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NotchStyle.accent)
                .symbolEffect(.bounce, value: model.hasUnseenResult)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NotchStyle.warning)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.stage {
        case .working(_, let work, _, let p):
            if let p {
                Text(p, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchStyle.text)
            } else {
                Image(systemName: work == .download ? "arrow.down" : "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchStyle.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        case .transcribed:
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchStyle.text)
        case .downloaded:
            Image(systemName: "film.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchStyle.text)
        default:
            EmptyView()
        }
    }
}

struct ProgressRing: View {
    let progress: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(NotchStyle.stroke, lineWidth: 2.2)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(NotchStyle.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(NotchStyle.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
    }
}

// MARK: - Open

struct OpenNotch: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var tm = TranscriptionManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                if model.isDropTargeted {
                    DropZone()
                } else {
                    content
                }
                if let downloading = tm.downloadingModel {
                    ModelDownloadLine(name: downloading.displayName, progress: tm.modelDownloadProgress)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
        .foregroundStyle(NotchStyle.text)
        .onKeyPress(.escape) { NotchController.shared.close(); return .handled }
    }

    /// Beside the hardware notch: the name on the left, the menu on the right.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NotchStyle.accent)
                Text(verbatim: "MindExtract")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchStyle.secondary)
            }
            Spacer(minLength: model.geometry.notchSize.width + 24)
            NotchMenu()
        }
        .padding(.horizontal, 16)
        .frame(height: max(30, model.geometry.notchSize.height))
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .idle:
            LinkField()
            RecentList()
        case .loadingInfo:
            LinkField()
            ItemCard(item: nil)
        case .ready(let item):
            ItemCard(item: item)
            ReadyActions(item: item)
        case .working(let item, _, let phase, let progress):
            ItemCard(item: item)
            WorkingRow(phase: phase, progress: progress)
        case .transcribed(let item, let path):
            ItemCard(item: item, badge: "checkmark.circle.fill")
            TranscribedActions(item: item, path: path)
        case .downloaded(let item, let path):
            ItemCard(item: item, badge: "checkmark.circle.fill")
            DownloadedActions(path: path)
        case .failed(let item, let message, let needsModel):
            if let item { ItemCard(item: item) } else { LinkField() }
            FailedRow(message: message, canRetry: item != nil, needsModel: needsModel)
        }
    }
}

// MARK: - Pieces

struct LinkField: View {
    @EnvironmentObject var model: NotchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let link = model.clipboardLink, model.input.isEmpty {
                Button { model.pasteClipboardLink() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Use copied link")
                            .font(.system(size: 12, weight: .semibold))
                        Text(verbatim: Self.shortLink(link))
                            .font(.system(size: 12))
                            .foregroundStyle(NotchStyle.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchStyle.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(NotchStyle.accent.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(NotchStyle.accent.opacity(0.22)))
                    .foregroundStyle(NotchStyle.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 10) {
                if case .loadingInfo = model.stage {
                    ProgressView().controlSize(.small).frame(width: 14)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NotchStyle.tertiary)
                        .frame(width: 14)
                }
                TextField("", text: $model.input, prompt: Text("Paste a link or drop a video").foregroundStyle(NotchStyle.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .disabled(model.isBusy)
                if !model.input.isEmpty, !model.isBusy {
                    Button { model.submit() } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(NotchStyle.accent))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NotchStyle.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? NotchStyle.accent.opacity(0.45) : NotchStyle.stroke))
        }
        .animation(NotchStyle.snappy, value: model.input.isEmpty)
        .animation(NotchStyle.snappy, value: model.clipboardLink)
        .onChange(of: focused) { _, f in model.isEditing = f }
    }

    static func shortLink(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else { return link }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h + url.path
    }
}

struct ItemCard: View {
    let item: NotchModel.Item?
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black, NotchStyle.accent)
                            .padding(4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                if let item {
                    Text(verbatim: item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.subtitle.isEmpty {
                        Text(verbatim: item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(NotchStyle.secondary)
                            .lineLimit(1)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(NotchStyle.field).frame(width: 240, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(NotchStyle.field).frame(width: 140, height: 10)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(NotchStyle.snappy, value: badge)
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = item?.thumbnail {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder(icon: "play.rectangle.fill")
                }
            }
        } else {
            placeholder(icon: item?.filePath != nil ? "film" : "play.rectangle.fill")
        }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            NotchStyle.field
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(NotchStyle.tertiary)
        }
    }
}

struct ReadyActions: View {
    @EnvironmentObject var model: NotchModel
    let item: NotchModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if item.url != nil {
                    Button { model.download() } label: {
                        Label(model.audioOnly ? "Download Audio" : "Download Video", systemImage: "arrow.down")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .secondary))
                }
                Button { model.transcribe() } label: {
                    Label("Transcribe", systemImage: "text.quote")
                }
                .buttonStyle(NotchButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 16) {
                Menu {
                    Picker("Spoken language", selection: $model.language) {
                        ForEach(AppSettings.transcriptionLanguages, id: \.code) { lang in
                            Text(verbatim: lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    OptionLabel(icon: "globe", text: languageName)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if item.url != nil {
                    Button { model.audioOnly.toggle() } label: {
                        OptionLabel(icon: model.audioOnly ? "waveform" : "film",
                                    text: model.audioOnly ? String(localized: "Audio only") : String(localized: "Video"))
                    }
                    .buttonStyle(.plain)
                    .help("What Download saves")
                }
                Spacer()
                Button { model.clear() } label: {
                    OptionLabel(icon: "xmark", text: String(localized: "Clear"))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var languageName: String {
        AppSettings.transcriptionLanguages.first { $0.code == model.language }?.name ?? model.language
    }
}

struct OptionLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(verbatim: text).font(.system(size: 12))
        }
        .foregroundStyle(NotchStyle.secondary)
        .contentShape(Rectangle())
    }
}

struct WorkingRow: View {
    @EnvironmentObject var model: NotchModel
    let phase: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressBar(progress: progress)
            HStack {
                Text(verbatim: phase)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotchStyle.secondary)
                if let progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(NotchStyle.text)
                }
                Spacer()
                Button { model.cancel() } label: {
                    OptionLabel(icon: "xmark", text: String(localized: "Cancel"))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProgressBar: View {
    let progress: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchStyle.field)
                if let progress {
                    Capsule()
                        .fill(NotchStyle.accent)
                        .frame(width: max(6, proxy.size.width * min(1, progress)))
                        .animation(.easeOut(duration: 0.35), value: progress)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, NotchStyle.accent, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * 0.35)
                        .offset(x: sweep ? proxy.size.width * 0.65 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

struct TranscribedActions: View {
    @EnvironmentObject var model: NotchModel
    let item: NotchModel.Item
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview {
                Text(verbatim: preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchStyle.secondary)
                    .lineLimit(3)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(NotchStyle.field))
            }
            HStack(spacing: 10) {
                Button {
                    model.copyTranscript(path: path, title: item.title, url: item.url, timestamps: false)
                } label: {
                    Label(copied ? "Copied — paste it anywhere" : "Copy Transcript",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(NotchButtonStyle(kind: .primary))
                .keyboardShortcut("c", modifiers: .command)
                Menu {
                    Button("Copy with Timestamps") {
                        model.copyTranscript(path: path, title: item.title, url: item.url, timestamps: true)
                    }
                    Divider()
                    Button("Open Transcript") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NotchStyle.field))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Button { model.clear() } label: {
                    OptionLabel(icon: "plus", text: String(localized: "New"))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(NotchStyle.snappy, value: copied)
    }

    private var copied: Bool { model.justCopied == path }

    private var preview: String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let text = TranscriptCopy.plain(String(raw.prefix(1200)))
        return text.isEmpty ? nil : text
    }
}

struct DownloadedActions: View {
    @EnvironmentObject var model: NotchModel
    let path: String

    var body: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(NotchButtonStyle(kind: .secondary))
            Button { model.transcribe() } label: {
                Label("Transcribe", systemImage: "text.quote")
            }
            .buttonStyle(NotchButtonStyle(kind: .primary))
            Spacer()
            Button { model.clear() } label: {
                OptionLabel(icon: "plus", text: String(localized: "New"))
            }
            .buttonStyle(.plain)
        }
    }
}

struct FailedRow: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var tm = TranscriptionManager.shared
    let message: String
    let canRetry: Bool
    let needsModel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchStyle.warning)
                Text(verbatim: message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(NotchStyle.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if needsModel {
                    Button { model.downloadSpeechModel() } label: {
                        Label("Download Speech Model", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(NotchButtonStyle(kind: .primary))
                    .disabled(tm.downloadingModel != nil)
                }
                if canRetry {
                    Button { model.transcribe() } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(NotchButtonStyle(kind: needsModel ? .secondary : .primary))
                    .disabled(tm.downloadingModel != nil)
                }
                Spacer()
                Button { model.clear() } label: {
                    OptionLabel(icon: "xmark", text: String(localized: "Clear"))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ModelDownloadLine: View {
    let name: String
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            ProgressRing(progress: progress > 0 ? progress : nil).frame(width: 13, height: 13)
            Text("Downloading \(name)…")
                .font(.system(size: 12))
                .foregroundStyle(NotchStyle.secondary)
            Spacer()
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(NotchStyle.secondary)
        }
    }
}

struct DropZone: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(NotchStyle.accent)
                .symbolEffect(.bounce, options: .repeating)
            Text("Drop to transcribe")
                .font(.system(size: 14, weight: .semibold))
            Text("Video or audio, any format")
                .font(.system(size: 12))
                .foregroundStyle(NotchStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NotchStyle.accent.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(NotchStyle.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

struct RecentList: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject private var transcripts = TranscriptionHistoryManager.shared
    @ObservedObject private var downloads = HistoryManager.shared

    var body: some View {
        let entries = RecentEntry.latest(3)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiary)
                    .padding(.leading, 4)
                ForEach(entries) { RecentRow(entry: $0) }
            }
        }
    }
}

struct RecentRow: View {
    @EnvironmentObject var model: NotchModel
    let entry: RecentEntry
    @State private var hovering = false

    var body: some View {
        Button(action: primary) {
            HStack(spacing: 10) {
                Image(systemName: entry.kind == .transcript ? "text.quote" : "film")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchStyle.secondary)
                    .frame(width: 16)
                Text(verbatim: entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchStyle.accent)
                } else if hovering {
                    Text(entry.kind == .transcript ? "Copy" : "Show")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchStyle.accent)
                } else {
                    Text(entry.date, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(NotchStyle.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? NotchStyle.field : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.kind == .transcript ? "Copy the transcript" : "Show in Finder")
    }

    private var copied: Bool { entry.path != nil && model.justCopied == entry.path }

    private func primary() {
        guard let path = entry.path else { return }
        switch entry.kind {
        case .transcript:
            model.copyTranscript(path: path, title: entry.title, url: entry.url, timestamps: false)
        case .download:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

struct NotchMenu: View {
    var body: some View {
        Menu {
            Button("Settings…") { SettingsWindow.show() }
            Button("Open Downloads Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: AppSettings.shared.downloadPath))
            }
            Divider()
            Button("Quit MindExtract") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchStyle.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Buttons

struct NotchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.black : NotchStyle.text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(kind == .primary ? NotchStyle.accent : (hovering ? NotchStyle.fieldHover : NotchStyle.field))
                    .opacity(kind == .primary && hovering ? 0.88 : 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind == .primary ? .clear : NotchStyle.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(NotchStyle.snappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}
