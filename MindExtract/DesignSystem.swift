import SwiftUI
import AppKit

/// Hides the window's title text and makes the titlebar transparent for a clean,
/// unified dark look (traffic lights + toolbar remain).
struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if window !== self.window {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                self.window = window
                // AppKit re-derives the title (to the bundle name) on every toolbar
                // refresh, so pin it hidden on each window update rather than once.
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hideTitle() }
                }
            }
            hideTitle()
        }

        private func hideTitle() {
            guard let window else { return }
            window.titleVisibility = .hidden
            // Keep a standard (non-transparent) titlebar so AppKit owns the strip —
            // this preserves native double-click-to-zoom and titlebar dragging.
            window.titlebarAppearsTransparent = false
            // performZoom is a no-op unless the window is resizable.
            window.styleMask.insert(.resizable)
            // Keep a non-empty accessible name (VoiceOver / Window menu) while the
            // title text stays visually hidden.
            if window.title.isEmpty { window.title = "MindExtract" }
        }
    }
}

/// A translucent vibrancy background (like Messages / Finder). With `.behindWindow`
/// blending the desktop shows through, so the app is never flat white.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Central design tokens so spacing, radius, typography and color are consistent
/// across the app instead of inline literals. Leans on native macOS materials and
/// the system look for a clean, premium, HIG-aligned feel.
enum DS {

    // MARK: - Spacing (4-pt grid)
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner radius
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let card: CGFloat = 12
    }

    // MARK: - Semantic colors
    /// One source of truth for functional color. The app uses the system accent
    /// for primary actions and a small, consistent set of category hues.
    enum Colors {
        /// Messages-style blue accent (replaces the loud system magenta).
        static let accent = Color(red: 0.0, green: 0.48, blue: 1.0)
        static let download = accent
        static let audio = Color(red: 0.55, green: 0.40, blue: 0.92)      // calm violet
        static let transcription = Color(red: 0.95, green: 0.55, blue: 0.20) // warm amber
        static let success = Color.green
        static let danger = Color.red
        static let warning = Color.orange

        static let secondaryText = Color.secondary
        /// Card / grouped surface — adapts to light/dark automatically.
        static let surface = Color(nsColor: .controlBackgroundColor)

        // Dark Messages-style canon (the app is dark-only):
        /// The app backdrop behind all content.
        static let backdrop = Color(red: 0.11, green: 0.11, blue: 0.12)
        /// Standard row/card fill floating on the backdrop.
        static let rowFill = Color.white.opacity(0.04)
        /// Hairline stroke around rows/cards.
        static let hairline = Color.white.opacity(0.07)
        /// Text-input fill (capsule fields).
        static let inputFill = Color.white.opacity(0.06)
        /// Text-input stroke.
        static let inputStroke = Color.white.opacity(0.12)
    }

    // MARK: - Typography ramp (semantic, scales with system)
    enum Typography {
        static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.semibold)
        static let section = Font.system(.headline)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let caption = Font.system(.caption)
        static let mono = Font.system(.caption, design: .monospaced)
        /// List/row titles across the app (History, Transcripts, etc.).
        static let rowTitle = Font.system(size: 14, weight: .medium)
        /// Transcript reading text.
        static let readingBody = Font.system(size: 14)
    }
}

extension View {
    /// Liquid Glass surface on macOS 26+, with a graceful material fallback on
    /// earlier macOS. Apply to floating panels, cards and control bars — not to
    /// plain content — for an Apple-style glass look.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = DS.Radius.card, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.fill(tint?.opacity(0.16) ?? .clear))
        }
    }

    /// Pads content then wraps it in a Liquid Glass card.
    func glassCard(padding: CGFloat = DS.Spacing.lg, cornerRadius: CGFloat = DS.Radius.card, tint: Color? = nil) -> some View {
        self.padding(padding).glassSurface(cornerRadius: cornerRadius, tint: tint)
    }

}

extension View {
    /// Canonical row/card chrome: hairline-stroked translucent fill on the dark
    /// backdrop. Use for every list row so they can't drift apart.
    func rowChrome(cornerRadius: CGFloat = 11, selected: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? DS.Colors.accent.opacity(0.14) : DS.Colors.rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(selected ? DS.Colors.accent.opacity(0.55) : DS.Colors.hairline, lineWidth: 1)
            )
    }

    /// Canonical status banner (info/success/warning/error cards).
    func statusBanner(_ tint: Color) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1))
            .cornerRadius(8)
    }
}

/// The one search field used across all lists (capsule input canon).
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Search…", text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DS.Colors.inputFill, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Colors.inputStroke, lineWidth: 1))
    }
}

// MARK: - Crisp button styles
// Glass blur reads as "out of focus" on small text, so buttons are crisp:
// primary = solid accent capsule (like the Messages send button), secondary =
// quiet neutral capsule with a hairline. Glass stays on large surfaces only.

struct SolidAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .lineLimit(1)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    (isEnabled ? DS.Colors.accent : Color.secondary.opacity(0.3))
                        .opacity(configuration.isPressed ? 0.75 : 1),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
    }
}

struct QuietCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .lineLimit(1)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Colors.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension View {
    /// Primary action button — crisp solid accent capsule. (Name kept from the
    /// earlier glass era so call sites didn't need to change.)
    func primaryGlassButton() -> some View {
        self.buttonStyle(SolidAccentButtonStyle())
    }

    /// Secondary action button — quiet neutral capsule.
    func secondaryGlassButton() -> some View {
        self.buttonStyle(QuietCapsuleButtonStyle())
    }

    /// A `Menu` styled to match `secondaryGlassButton()` — same quiet capsule,
    /// so dropdown actions (Export, etc.) look identical to plain buttons next
    /// to them instead of falling back to the system's bordered menu chrome.
    func secondaryMenu() -> some View {
        self.menuStyle(.button).buttonStyle(QuietCapsuleButtonStyle())
    }

    /// One-line chrome text that never wraps mid-word — for toolbar/header
    /// labels, tabs, pills, and any control text. Truncates with "…" instead.
    /// `fixedSize` keeps the label from being compressed into a wrap by a
    /// crowded HStack; use the default for labels that should hold their width,
    /// and `flexible: true` for a title that should truncate to share space.
    func chromeText(_ truncation: Text.TruncationMode = .tail, flexible: Bool = false) -> some View {
        self
            .lineLimit(1)
            .truncationMode(truncation)
            .fixedSize(horizontal: !flexible, vertical: false)
    }

    /// Multi-line body text (titles, descriptions) capped at a few lines with
    /// clean tail truncation — never an awkward mid-word break.
    func readingText(lines: Int = 2) -> some View {
        self
            .lineLimit(lines)
            .truncationMode(.tail)
    }
}
