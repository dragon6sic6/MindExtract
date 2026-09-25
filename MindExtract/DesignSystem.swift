import SwiftUI
import AppKit

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
/// across the app instead of inline literals. Everything adapts to light/dark mode,
/// Increase Contrast and the user's accent color. Liquid Glass is reserved for the
/// controls layer (toolbar, floating bars, HUDs) — content sits on plain surfaces.
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
        /// Follows the user's system accent color (System Settings → Appearance).
        static let accent = Color.accentColor
        static let download = accent
        static let audio = Color(red: 0.55, green: 0.40, blue: 0.92)      // calm violet
        static let transcription = Color(red: 0.95, green: 0.55, blue: 0.20) // warm amber
        static let success = Color.green
        static let danger = Color.red
        static let warning = Color.orange

        static let secondaryText = Color.secondary
        /// Card / grouped surface — adapts to light/dark automatically.
        static let surface = Color(nsColor: .controlBackgroundColor)

        /// Recording — the only place red is used as a brand color.
        static let recording = Color.red

        // Adaptive surfaces (light + dark + increased contrast, from AppKit):
        /// The content backdrop — the same "paper" as Notes/Mail.
        static let backdrop = Color(nsColor: .textBackgroundColor)
        /// Standard row/card fill on the backdrop.
        static let rowFill = Color(nsColor: .quinarySystemFill)
        /// Hairline stroke around rows/cards.
        static let hairline = Color(nsColor: .separatorColor)
        /// Text-input fill.
        static let inputFill = Color(nsColor: .quaternarySystemFill)
        /// Text-input stroke.
        static let inputStroke = Color(nsColor: .separatorColor)
    }

    // MARK: - Typography ramp (semantic, scales with system)
    enum Typography {
        static let largeTitle = Font.system(.largeTitle).weight(.bold)
        static let title = Font.system(.title2).weight(.semibold)
        static let section = Font.system(.headline)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let caption = Font.system(.caption)
        static let mono = Font.system(.caption, design: .monospaced)
        /// List/row titles across the app (History, Transcripts, etc.).
        static let rowTitle = Font.system(.body).weight(.medium)
        /// Transcript reading text.
        static let readingBody = Font.system(size: 14)
    }
}

extension View {
    /// Liquid Glass — for the controls layer only (floating bars, HUDs, overlays
    /// above content). Never on content cards; use `contentCard` for those.
    func glassSurface(cornerRadius: CGFloat = DS.Radius.card, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
    }

    /// A content-layer card: quiet adaptive fill + hairline, no glass.
    func contentCard(padding: CGFloat = DS.Spacing.lg, cornerRadius: CGFloat = DS.Radius.lg, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.padding(padding)
            .background(shape.fill(tint?.opacity(0.08) ?? DS.Colors.rowFill))
            .overlay(shape.strokeBorder(DS.Colors.hairline, lineWidth: 0.5))
    }

    /// Kept for existing call sites — now a content card (glass is for controls).
    func glassCard(padding: CGFloat = DS.Spacing.lg, cornerRadius: CGFloat = DS.Radius.card, tint: Color? = nil) -> some View {
        self.contentCard(padding: padding, cornerRadius: cornerRadius, tint: tint)
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
                    .strokeBorder(selected ? DS.Colors.accent.opacity(0.55) : DS.Colors.hairline, lineWidth: 0.5)
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
    var placeholder: String = "Search…"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: $text)
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

// MARK: - Buttons
// Native macOS 26 buttons: they pick up the accent color, Increase Contrast and
// the system's Liquid Glass treatment automatically.

extension View {
    /// Primary action — prominent capsule in the accent color.
    func primaryGlassButton() -> some View {
        self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
    }

    /// Secondary action — standard bordered capsule.
    func secondaryGlassButton() -> some View {
        self.buttonStyle(.bordered).buttonBorderShape(.capsule)
    }

    /// A `Menu` that matches `secondaryGlassButton()`.
    func secondaryMenu() -> some View {
        self.menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.capsule)
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
