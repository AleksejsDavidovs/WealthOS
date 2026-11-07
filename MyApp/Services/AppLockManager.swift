import Foundation
import LocalAuthentication
import Observation

/// Face ID / Touch ID with automatic device-passcode fallback
/// (`.deviceOwnerAuthentication`). No credentials are stored by the app.
@Observable
final class AppLockManager {
    var isLocked: Bool
    var isAuthenticating = false
    var errorMessage: String?

    init() {
        isLocked = UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled)
    }

    var isLockEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled) }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var biometrySymbol: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lockIfEnabled() {
        if isLockEnabled { isLocked = true }
    }

    /// Prompts for authentication. Returns true on success.
    @discardableResult
    func authenticate(reason: String = "Unlock your financial data") async -> Bool {
        guard !isAuthenticating else { return false }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode is set on the device, so the lock cannot be enforced.
            errorMessage = "Set a device passcode in iOS Settings to use the app lock."
            isLocked = false
            return false
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                isLocked = false
                errorMessage = nil
            }
            return success
        } catch {
            errorMessage = (error as? LAError)?.code == .userCancel ? nil : "Authentication failed. Try again."
            return false
        }
    }

    /// Enabling the lock requires a successful authentication first.
    func setLockEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            let context = LAContext()
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                errorMessage = "Set a device passcode in iOS Settings to use the app lock."
                return false
            }
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                     localizedReason: "Enable the WealthOS lock")) == true else { return false }
        }
        UserDefaults.standard.set(enabled, forKey: SettingsKey.lockEnabled)
        if !enabled {
            isLocked = false
            errorMessage = nil
        }
        return true
    }
}
