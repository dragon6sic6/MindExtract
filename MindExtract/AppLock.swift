import SwiftUI
import LocalAuthentication

// MARK: - App lock (Touch ID / device password)
//
// Gates the app behind the user's biometrics or device password so transcripts
// (client/patient/case material) aren't visible to anyone who walks up to an
// unlocked Mac. Opt-in. This protects *access*; full at-rest disk encryption is
// macOS FileVault's job (surfaced as guidance in Settings).

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var isLocked = false
    private var authenticating = false

    private init() {}

    var isEnabled: Bool { AppSettings.shared.appLockEnabled }

    /// Lock the UI if the feature is on (called on launch and when the app is
    /// no longer frontmost). Skipped while recording so a meeting (where you're
    /// in Zoom/Teams, not MindExtract) isn't interrupted by repeated unlocks.
    func lockIfEnabled() {
        guard isEnabled, !MeetingRecorder.shared.isBusy else { return }
        isLocked = true
    }

    /// Prompt for Touch ID / password to unlock.
    func authenticate() {
        guard isLocked, !authenticating else { return }
        authenticating = true
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Password"
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication   // biometrics, then password
        guard ctx.canEvaluatePolicy(policy, error: &error) else {
            // No biometrics/password configured — don't trap the user out.
            isLocked = false
            authenticating = false
            return
        }
        ctx.evaluatePolicy(policy, localizedReason: "Unlock MindExtract to view your transcripts") { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                if ok { self.isLocked = false }
            }
        }
    }
}

// MARK: - Lock screen

struct LockView: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.accent)
                Text("MindExtract is locked")
                    .font(.system(size: 18, weight: .semibold))
                Text("Your transcripts are private. Unlock with Touch ID or your password.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button {
                    lock.authenticate()
                } label: {
                    Label("Unlock", systemImage: "touchid").frame(maxWidth: 200)
                }
                .primaryGlassButton()
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .onAppear { lock.authenticate() }
    }
}
