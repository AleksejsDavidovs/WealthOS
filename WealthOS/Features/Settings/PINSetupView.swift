import SwiftUI

/// Creates or replaces the WealthOS PIN with the same full-screen pad used to unlock.
/// Presented as a full-screen cover only after a fresh Face ID / passcode check
/// (`AppLockManager.reauthorize`) or right after the lock was enabled, which required one.
/// If the app locks meanwhile, the secure overlay window covers this screen too.
struct PINSetupView: View {
    @Environment(AppLockManager.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage: Stage = .create
    @State private var firstEntry = ""
    @State private var digits = ""
    @State private var feedback: PINPadFeedback = .idle
    @State private var shakeTrigger = 0
    @State private var message: String?
    @State private var isSaving = false

    private enum Stage { case create, confirm }

    var body: some View {
        PINPadScreen(
            icon: feedback == .success ? "checkmark.shield.fill" : (stage == .create ? "circle.grid.3x3.fill" : "checkmark.shield"),
            title: title,
            subtitle: stage == .create
                ? "Used when \(lock.biometryName) isn't available. It's separate from your iPhone passcode."
                : "Enter the same 6 digits again.",
            filled: digits.count,
            feedback: feedback,
            shakeTrigger: shakeTrigger,
            message: message,
            messageIsError: feedback == .error,
            keypadEnabled: !isSaving && feedback != .success,
            onDigit: append,
            onDelete: { if !digits.isEmpty { digits.removeLast() } }
        ) {
            VStack(spacing: 10) {
                Text("If you forget it, unlock with \(lock.biometryName) or your iPhone passcode, then set a new PIN here. Your data is never deleted after wrong attempts.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Button("Not Now") {
                    clear()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PINPadStyle.turquoise)
                .disabled(isSaving)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: stage)
        // Don't keep a half-entered PIN around while the app is covered or backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && !isSaving { restart(message: nil) }
        }
        .onDisappear(perform: clear)
    }

    private var title: String {
        switch stage {
        case .create: lock.isPINEnabled ? "New WealthOS PIN" : "Create WealthOS PIN"
        case .confirm: "Confirm WealthOS PIN"
        }
    }

    private func append(_ digit: Int) {
        guard digits.count < AppPINManager.pinLength, !isSaving else { return }
        if feedback == .error { feedback = .idle; message = nil }
        digits.append(String(digit))
        guard digits.count == AppPINManager.pinLength else { return }

        switch stage {
        case .create:
            let entered = digits
            Task {
                try? await Task.sleep(for: .milliseconds(180))   // let the sixth dot land
                guard stage == .create, digits == entered else { return }
                firstEntry = entered
                digits = ""
                stage = .confirm
            }
        case .confirm:
            guard digits == firstEntry else {
                feedback = .error
                shakeTrigger += 1
                message = "PINs didn't match. Start again."
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    restart(message: "PINs didn't match. Start again.")
                }
                return
            }
            save(digits)
        }
    }

    private func save(_ newPIN: String) {
        isSaving = true
        Task {
            do {
                try await lock.enrollPIN(newPIN)
                feedback = .success
                message = "WealthOS PIN saved."
                try? await Task.sleep(for: .milliseconds(650))
                clear()
                dismiss()
            } catch {
                isSaving = false
                feedback = .error
                shakeTrigger += 1
                message = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(450))
                restart(message: error.localizedDescription)
            }
        }
    }

    private func restart(message newMessage: String?) {
        clear()
        message = newMessage
        if newMessage != nil { feedback = .error }
    }

    private func clear() {
        digits = ""
        firstEntry = ""
        stage = .create
        feedback = .idle
        message = nil
    }
}
