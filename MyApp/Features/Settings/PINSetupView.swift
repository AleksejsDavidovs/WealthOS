import SwiftUI

/// Creates or replaces the app's 6-digit PIN fallback. Presented only after a fresh
/// Face ID / device-passcode check (`AppLockManager.reauthorize`) or right after the lock
/// was enabled, which itself required one.
struct PINSetupView: View {
    @Environment(AppLockManager.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .enter
    @State private var firstEntry = ""
    @State private var input = ""
    @State private var errorMessage: String?

    private enum Stage { case enter, confirm }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "number.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                Text(stage == .enter ? "Create a 6-Digit PIN" : "Confirm Your PIN")
                    .font(.title2.bold())
                Text("Used as a backup when \(lock.biometryName) isn't available. \(lock.biometryName) and your device passcode remain the primary ways to unlock WealthOS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                PINDigitsField(value: $input, length: 6, tint: Theme.accent) { submit() }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                Spacer()

                Text("If you forget your PIN, unlock with \(lock.biometryName) or your device passcode, then set a new PIN from Settings. Your financial data is never deleted after failed attempts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
            .padding()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(stage == .confirm)
        .onDisappear {
            input = ""
            firstEntry = ""
        }
    }

    private func submit() {
        guard AppPINManager.isValidFormat(input) else {
            errorMessage = "Enter exactly six digits."
            input = ""
            return
        }
        switch stage {
        case .enter:
            firstEntry = input
            input = ""
            errorMessage = nil
            stage = .confirm
        case .confirm:
            guard input == firstEntry else {
                errorMessage = "PINs don't match. Try again."
                input = ""
                firstEntry = ""
                stage = .enter
                return
            }
            do {
                try lock.enrollPIN(input)
                input = ""
                firstEntry = ""
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                input = ""
            }
        }
    }
}
