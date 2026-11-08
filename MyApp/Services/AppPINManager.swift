import Foundation
import CommonCrypto
import Security

nonisolated enum PINError: LocalizedError {
    case invalidFormat
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Enter exactly six digits."
        case .keyDerivationFailed: "Could not secure the PIN. Try again."
        }
    }
}

/// Result of checking a candidate PIN. `incorrect` reports how many more wrong guesses are
/// allowed before the next progressive lockout; `lockedOut` reports the remaining wait.
nonisolated enum PINVerificationResult: Equatable {
    case success
    case incorrect(remainingBeforeLockout: Int)
    case lockedOut(retryAfter: TimeInterval)
    case notEnrolled
}

/// Stores and verifies a six-digit app PIN without ever persisting it in plaintext.
///
/// Design:
/// - The PIN itself is never stored. Only a PBKDF2-HMAC-SHA256 hash of it, salted with 16
///   random bytes, lives in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
///   not synced to iCloud, never included in WealthOS backups) — the same pattern already
///   used for market-data API keys (`KeychainStore`) and backup passwords (`BackupCrypto`).
/// - A 6-digit PIN has only one million possible values. PBKDF2 alone cannot make an
///   *offline* brute force of an extracted Keychain blob (e.g. via jailbreak) infeasible —
///   no amount of reasonable key-stretching can, for a secret this short. The actual defense
///   against guessing is the progressive on-device lockout below, which makes *online*
///   (through-the-UI) guessing impractical. This tradeoff is inherent to short numeric PINs
///   and is documented for the user; biometrics/device passcode remain the primary unlock
///   methods and are never weaker than this fallback.
/// - Failure counters and lockout expiry are themselves stored in the Keychain (not
///   UserDefaults) so they can't be trivially cleared to reset the lockout.
final class AppPINManager: @unchecked Sendable {
    private let store: SecretStore
    private let verifierAccount = "pinVerifier"
    private let stateAccount = "pinAttemptState"
    private let iterations: UInt32 = 200_000
    private let saltLength = 16
    private let hashLength = 32
    private let maxAttemptsBeforeFirstLockout = 3

    init(store: SecretStore = KeychainStore(service: "WealthOS.AppLock")) {
        self.store = store
    }

    var isEnrolled: Bool { store.read(verifierAccount) != nil }

    static func isValidFormat(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Replaces any existing PIN. Callers should only reach this after the user has already
    /// authenticated (Settings is lock-gated), and after requiring a matching confirmation.
    func enroll(_ newPIN: String) throws {
        guard Self.isValidFormat(newPIN) else { throw PINError.invalidFormat }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PINError.keyDerivationFailed }
        let hash = try Self.deriveHash(pin: newPIN, salt: salt, iterations: iterations, length: hashLength)
        let verifier = (salt + hash).base64EncodedString()
        try store.save(verifier, account: verifierAccount)
        saveState(AttemptState())
    }

    /// Does not touch financial data; only removes the PIN verifier and its attempt counters.
    func disable() {
        try? store.delete(verifierAccount)
        try? store.delete(stateAccount)
    }

    func verify(_ candidate: String) -> PINVerificationResult {
        guard let verifierString = store.read(verifierAccount),
              let verifierData = Data(base64Encoded: verifierString),
              verifierData.count == saltLength + hashLength else { return .notEnrolled }

        var state = loadState()
        let now = Date.now.timeIntervalSince1970
        if state.lockedUntil > now {
            return .lockedOut(retryAfter: state.lockedUntil - now)
        }

        let salt = Data(verifierData.prefix(saltLength))
        let expectedHash = Data(verifierData.suffix(hashLength))
        let matches = Self.isValidFormat(candidate)
            && (try? Self.deriveHash(pin: candidate, salt: salt, iterations: iterations, length: hashLength))
                .map { Self.constantTimeEquals($0, expectedHash) } == true

        guard matches else {
            state.failedAttempts += 1
            let delay = Self.lockoutDuration(forFailedAttempts: state.failedAttempts)
            state.lockedUntil = delay > 0 ? now + delay : 0
            saveState(state)
            if delay > 0 { return .lockedOut(retryAfter: delay) }
            return .incorrect(remainingBeforeLockout: max(0, maxAttemptsBeforeFirstLockout - state.failedAttempts))
        }

        saveState(AttemptState())
        return .success
    }

    /// Progressive backoff: friction ramps up quickly so a six-digit space (1,000,000
    /// combinations) cannot be exhausted in any practical amount of time through the UI.
    static func lockoutDuration(forFailedAttempts failures: Int) -> TimeInterval {
        switch failures {
        case ..<3: return 0
        case 3: return 30
        case 4: return 60
        case 5: return 300
        default: return 900
        }
    }

    private struct AttemptState: Codable {
        var failedAttempts: Int = 0
        var lockedUntil: TimeInterval = 0
    }

    private func loadState() -> AttemptState {
        guard let raw = store.read(stateAccount), let data = Data(base64Encoded: raw),
              let state = try? JSONDecoder().decode(AttemptState.self, from: data) else { return AttemptState() }
        return state
    }

    private func saveState(_ state: AttemptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? store.save(data.base64EncodedString(), account: stateAccount)
    }

    private static func deriveHash(pin: String, salt: Data, iterations: UInt32, length: Int) throws -> Data {
        let pinData = Data(pin.utf8)
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                pinData.withUnsafeBytes { pinBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: CChar.self), pinData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw PINError.keyDerivationFailed }
        return derived
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
