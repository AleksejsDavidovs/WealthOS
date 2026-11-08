import Foundation
import LocalAuthentication
import Observation

/// Thin seam over `LAContext` so unit tests can simulate Face ID success, failure,
/// cancellation and lockout without touching real biometric hardware.
protocol BiometricAuthenticating: Sendable {
    func canEvaluate(_ policy: LAPolicy) -> Bool
    func evaluate(_ policy: LAPolicy, reason: String, fallbackTitle: String?) async throws -> Bool
}

struct LAContextAuthenticator: BiometricAuthenticating {
    func canEvaluate(_ policy: LAPolicy) -> Bool {
        LAContext().canEvaluatePolicy(policy, error: nil)
    }

    func evaluate(_ policy: LAPolicy, reason: String, fallbackTitle: String?) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        if let fallbackTitle { context.localizedFallbackTitle = fallbackTitle }
        return try await context.evaluatePolicy(policy, localizedReason: reason)
    }
}

/// App lock state machine.
///
/// Unlock methods:
/// - No app PIN: `.deviceOwnerAuthentication` — Face ID, with the system's own device-passcode
///   fallback inside the same prompt (the pre-existing behavior).
/// - App PIN set: Face ID only, with the prompt's fallback button relabeled "Use PIN". After
///   repeated failures, lockout, or on request the PIN screen is offered, and the device
///   passcode stays reachable from there, so a forgotten PIN never locks the owner out.
@MainActor
@Observable
final class AppLockManager {
    var isLocked: Bool
    private(set) var isAuthenticating = false
    var errorMessage: String?
    private(set) var isPINEnabled: Bool
    private(set) var isVerifyingPIN = false
    var showPINEntry = false

    /// Failed Face ID *prompts* this lock session. LocalAuthentication doesn't report
    /// individual match attempts inside one prompt, so this counts our own calls.
    private(set) var biometricFailureCount = 0
    static let maxBiometricFailuresBeforePIN = 3

    /// Allows exactly one automatic prompt per lock session. Presenting Face ID itself makes
    /// the scene go inactive→active, so without this the prompt would re-trigger itself.
    private var autoPromptArmed = true
    /// Bumped on every relock; a prompt that started in an older session can't unlock a newer one.
    private var lockSession = 0

    let pin: AppPINManager
    private let biometrics: BiometricAuthenticating

    init(biometrics: BiometricAuthenticating = LAContextAuthenticator(), pin: AppPINManager = AppPINManager()) {
        isLocked = UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled)
        self.biometrics = biometrics
        self.pin = pin
        isPINEnabled = pin.isEnrolled
    }

    var isLockEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled) }
    var isPINUsable: Bool { isPINEnabled && !pin.isDisabledByFailures }

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

    /// Call when the app backgrounds. Starts a fresh lock session.
    func lockIfEnabled() {
        guard isLockEnabled else { return }
        isLocked = true
        lockSession += 1
        autoPromptArmed = true
        biometricFailureCount = 0
        showPINEntry = false
        errorMessage = nil
    }

    /// Safe to call on every activation: no-op unless locked, idle and not yet used this session.
    func authenticateAutomatically() {
        guard isLocked, !isAuthenticating, !showPINEntry, autoPromptArmed else { return }
        autoPromptArmed = false
        Task { await authenticate() }
    }

    func requestPINEntry() {
        guard isPINEnabled else { return }
        showPINEntry = true
    }

    func cancelPINEntry() {
        showPINEntry = false
    }

    var canUseBiometrics: Bool { biometrics.canEvaluate(.deviceOwnerAuthenticationWithBiometrics) }

    /// With a usable app PIN: Face ID only, and the WealthOS PIN is the fallback — including
    /// when Face ID is locked out or unavailable. Without one: `.deviceOwnerAuthentication`,
    /// whose only fallback is Apple's system passcode sheet. Returns true on unlock.
    @discardableResult
    func authenticate(reason: String = "Unlock your financial data") async -> Bool {
        guard isPINUsable else {
            return await evaluateUnlock(policy: .deviceOwnerAuthentication, reason: reason, fallbackTitle: nil)
        }
        guard canUseBiometrics else {
            showPINEntry = true
            return false
        }
        return await evaluateUnlock(policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason, fallbackTitle: "Use PIN")
    }

    /// Recovery path from the PIN screen: device passcode (or Face ID) via the system prompt.
    @discardableResult
    func authenticateWithDevicePasscode() async -> Bool {
        await evaluateUnlock(policy: .deviceOwnerAuthentication, reason: "Unlock your financial data", fallbackTitle: nil)
    }

    private func evaluateUnlock(policy: LAPolicy, reason: String, fallbackTitle: String?) async -> Bool {
        guard !isAuthenticating else { return false }
        guard biometrics.canEvaluate(policy) else {
            if isPINUsable {
                showPINEntry = true
            } else if !biometrics.canEvaluate(.deviceOwnerAuthentication) {
                // No device passcode exists, so iOS can't verify the owner at all and the lock
                // can't be enforced (pre-existing policy; removing the passcode requires it).
                errorMessage = "Set a device passcode in iOS Settings to use the app lock."
                isLocked = false
            }
            return false
        }

        let session = lockSession
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let success = try await biometrics.evaluate(policy, reason: reason, fallbackTitle: fallbackTitle)
            guard success, session == lockSession, isLocked else { return false }
            unlock()
            return true
        } catch let laError as LAError {
            handleFailure(laError, biometricsOnly: policy == .deviceOwnerAuthenticationWithBiometrics)
            return false
        } catch {
            errorMessage = "Authentication failed. Try again."
            return false
        }
    }

    /// Checks the PIN off the main thread (PBKDF2 takes ~100 ms) so the keypad can animate.
    /// Returns nil if ignored: not locked, or a check is already running — concurrent checks
    /// would race on the attempt counter.
    @discardableResult
    func verifyPIN(_ candidate: String) async -> PINVerificationResult? {
        guard isLocked, !isVerifyingPIN else { return nil }
        isVerifyingPIN = true
        defer { isVerifyingPIN = false }
        let session = lockSession
        let pin = self.pin
        let result = await Task.detached(priority: .userInitiated) { pin.verify(candidate) }.value
        if case .success = result, session == lockSession, isLocked { unlock() }
        return result
    }

    /// Remaining PIN lockout, if any. Read-only: never counts as an attempt.
    func pinLockoutRemaining(now: Date = .now) -> TimeInterval? {
        pin.lockoutRemaining(now: now)
    }

    /// Fresh device-owner authentication before any security-setting change, so someone
    /// handed the already-unlocked app can't set, change or remove the lock or PIN.
    func reauthorize(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        guard biometrics.canEvaluate(.deviceOwnerAuthentication) else {
            errorMessage = "Set a device passcode in iOS Settings to use the app lock."
            return false
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        return (try? await biometrics.evaluate(.deviceOwnerAuthentication, reason: reason, fallbackTitle: nil)) == true
    }

    /// Only call after `reauthorize` succeeded. Hashing runs off the main thread.
    func enrollPIN(_ newPIN: String) async throws {
        let pin = self.pin
        try await Task.detached(priority: .userInitiated) { try pin.enroll(newPIN) }.value
        isPINEnabled = true
    }

    /// Only call after `reauthorize` succeeded.
    func disablePIN() {
        pin.disable()
        isPINEnabled = false
        showPINEntry = false
    }

    /// Turning the lock on or off both require authenticating as the device owner.
    func setLockEnabled(_ enabled: Bool) async -> Bool {
        if enabled || canAuthenticate {
            let reason = enabled ? "Enable the WealthOS lock" : "Turn off the WealthOS lock"
            guard await reauthorize(reason: reason) else { return false }
        }
        UserDefaults.standard.set(enabled, forKey: SettingsKey.lockEnabled)
        if !enabled {
            isLocked = false
            showPINEntry = false
        }
        errorMessage = nil
        return true
    }

    private func unlock() {
        isLocked = false
        errorMessage = nil
        biometricFailureCount = 0
        showPINEntry = false
    }

    private func handleFailure(_ error: LAError, biometricsOnly: Bool) {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            errorMessage = nil
        case .userFallback:
            errorMessage = nil
            if isPINUsable { showPINEntry = true }
        case .biometryLockout:
            errorMessage = "\(biometryName) is temporarily locked. Use your PIN or device passcode."
            if isPINUsable { showPINEntry = true }
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            errorMessage = nil
            if isPINUsable { showPINEntry = true }
        default:
            errorMessage = "Authentication failed. Try again."
            guard biometricsOnly else { return }
            biometricFailureCount += 1
            if biometricFailureCount >= Self.maxBiometricFailuresBeforePIN, isPINUsable {
                showPINEntry = true
            }
        }
    }
}
