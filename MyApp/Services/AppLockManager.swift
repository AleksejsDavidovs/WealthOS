import Foundation
import LocalAuthentication
import Observation

/// Thin seam over `LAContext` so unit tests can simulate Face ID success, failure,
/// cancellation and lockout without touching real biometric hardware.
protocol BiometricAuthenticating: Sendable {
    func canEvaluate(_ policy: LAPolicy) -> Bool
    func evaluate(_ policy: LAPolicy, reason: String) async throws -> Bool
}

struct LAContextAuthenticator: BiometricAuthenticating {
    func canEvaluate(_ policy: LAPolicy) -> Bool {
        LAContext().canEvaluatePolicy(policy, error: nil)
    }

    func evaluate(_ policy: LAPolicy, reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        return try await context.evaluatePolicy(policy, localizedReason: reason)
    }
}

/// Face ID / Touch ID with an optional six-digit app PIN as a secondary, offline fallback.
/// No credentials are stored by the app in plaintext; see `AppPINManager` for the PIN's
/// storage and rate-limiting design. The device passcode (via `LAPolicy.deviceOwnerAuthentication`)
/// remains available as the ultimate recovery path whenever biometrics are unavailable.
@MainActor
@Observable
final class AppLockManager {
    var isLocked: Bool
    var isAuthenticating = false
    var errorMessage: String?

    /// Failures of our own `evaluatePolicy` calls while unlocked, not a count of individual
    /// Face ID match attempts inside one system prompt — LocalAuthentication deliberately
    /// doesn't expose that. Reset whenever a new lock session starts or unlock succeeds.
    private(set) var biometricFailureCount = 0
    var showPINEntry = false

    /// Armed once per lock session so the automatic Face ID prompt fires exactly once per
    /// background→foreground cycle. Consumed on the first attempt; manual retries (the
    /// "Unlock with Face ID" / "Use PIN" buttons) are never gated by this flag.
    private var autoPromptArmed = true

    static let maxBiometricFailuresBeforePIN = 3

    let pin: AppPINManager
    private let biometrics: BiometricAuthenticating

    init(biometrics: BiometricAuthenticating = LAContextAuthenticator(), pin: AppPINManager = AppPINManager()) {
        isLocked = UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled)
        self.biometrics = biometrics
        self.pin = pin
    }

    var isLockEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled) }
    var isPINEnabled: Bool { pin.isEnrolled }

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
        biometrics.canEvaluate(.deviceOwnerAuthentication)
    }

    /// Call when the app backgrounds. Starts a fresh lock session: the next foreground
    /// transition gets exactly one automatic Face ID attempt.
    func lockIfEnabled() {
        guard isLockEnabled else { return }
        isLocked = true
        autoPromptArmed = true
        biometricFailureCount = 0
        showPINEntry = false
        errorMessage = nil
    }

    /// Triggers Face ID automatically, at most once per lock session. Safe to call on every
    /// `scenePhase` change — it is a no-op unless locked, idle, and not yet consumed this session.
    func authenticateAutomatically() {
        guard isLocked, !isAuthenticating, autoPromptArmed else { return }
        autoPromptArmed = false
        Task { await authenticate() }
    }

    func requestPINEntry() {
        guard pin.isEnrolled else { return }
        showPINEntry = true
    }

    func cancelPINEntry() {
        showPINEntry = false
    }

    /// Prompts for authentication. Returns true on success.
    @discardableResult
    func authenticate(reason: String = "Unlock your financial data") async -> Bool {
        guard !isAuthenticating else { return false }
        let usesBiometricsOnly = biometrics.canEvaluate(.deviceOwnerAuthenticationWithBiometrics)
        let policy: LAPolicy = usesBiometricsOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication

        guard biometrics.canEvaluate(policy) else {
            if pin.isEnrolled {
                showPINEntry = true
            } else {
                // No passcode is set on the device, so the lock cannot be enforced.
                errorMessage = "Set a device passcode in iOS Settings to use the app lock."
                isLocked = false
            }
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let success = try await biometrics.evaluate(policy, reason: reason)
            if success { unlock() }
            return success
        } catch let laError as LAError {
            handleFailure(laError, usedBiometricsOnly: usesBiometricsOnly)
            return false
        } catch {
            errorMessage = "Authentication failed. Try again."
            return false
        }
    }

    @discardableResult
    func verifyPIN(_ candidate: String) -> PINVerificationResult {
        let result = pin.verify(candidate)
        if case .success = result { unlock() }
        return result
    }

    func enrollPIN(_ newPIN: String) throws {
        try pin.enroll(newPIN)
    }

    func disablePIN() {
        pin.disable()
    }

    /// Enabling the lock requires a successful authentication first.
    func setLockEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard biometrics.canEvaluate(.deviceOwnerAuthentication) else {
                errorMessage = "Set a device passcode in iOS Settings to use the app lock."
                return false
            }
            guard (try? await biometrics.evaluate(.deviceOwnerAuthentication,
                                                   reason: "Enable the WealthOS lock")) == true else { return false }
        }
        UserDefaults.standard.set(enabled, forKey: SettingsKey.lockEnabled)
        if !enabled {
            isLocked = false
            errorMessage = nil
        }
        return true
    }

    private func unlock() {
        isLocked = false
        errorMessage = nil
        biometricFailureCount = 0
        showPINEntry = false
    }

    private func handleFailure(_ error: LAError, usedBiometricsOnly: Bool) {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            errorMessage = nil
        case .biometryLockout:
            errorMessage = "\(biometryName) is temporarily unavailable after too many attempts."
            if pin.isEnrolled { showPINEntry = true }
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            errorMessage = nil
            if pin.isEnrolled { showPINEntry = true }
        default:
            errorMessage = "Authentication failed. Try again."
            guard usedBiometricsOnly else { return }
            biometricFailureCount += 1
            if biometricFailureCount >= Self.maxBiometricFailuresBeforePIN, pin.isEnrolled {
                showPINEntry = true
            }
        }
    }
}
