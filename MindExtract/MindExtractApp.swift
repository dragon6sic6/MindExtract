import SwiftUI

@main
struct MindExtractApp: App {
    @StateObject private var settings = AppSettings.shared
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(Color(NSColor.labelColor))
                .onAppear { applyAppearance(settings.appearanceMode) }
                .onChange(of: settings.appearanceMode) { applyAppearance($0) }
                .overlay {
                    if !hasSeenOnboarding {
                        OnboardingView(onDismiss: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                hasSeenOnboarding = true
                            }
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: hasSeenOnboarding)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("MindExtract Help") {
                    if let url = URL(string: "https://github.com/dragon6sic6/MindExtract#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

// MARK: - Helpers

private func applyAppearance(_ mode: AppearanceMode) {
    switch mode {
    case .system: NSApp.appearance = nil
    case .light:  NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}
