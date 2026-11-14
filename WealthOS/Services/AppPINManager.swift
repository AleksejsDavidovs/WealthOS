import Foundation
import CommonCrypto
import Security

nonisolated enum PINError: LocalizedError {
    case invalidFormat
    case keyDerivationFailed
    case storageFailed
    case removalFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Enter exactly six digits."
        case .keyDerivationFailed: "Could not secure the PIN. Try again."
        case .storageFailed: "The PIN couldn't be saved to the Keychain. Try again."
        case .removalFailed: "The PIN couldn't be removed from the Keychain, so it is still active. Try again."
        }
    }
}

/// Result of checking a candidate PIN.
nonisolated enum PINVerificationResult: Equatable {
    case success
    /// Wrong PIN; `remainingBeforeLockout` more wrong guesses are allowed before a delay starts.
    case incorrect(remainingBeforeLockout: Int)
    case lockedOut(retryAfter: TimeInterval)
    /// Too many wrong guesses in total. The PIN stays unusable until it is set again from
    /// Settings, which requires Face ID / device passcode. Financial data is never touched.
    case disabled
    case notEnrolled
    /// The PIN or its attempt counter couldn't be read (device locked, Keychain error or a
    /// corrupt record). Nothing was checked or counted; use Face ID or the device passcode.
    case unavailable
}

/// Stores and verifies a six-digit app PIN without ever persisting it in plaintext.
///
/// - Only a PBKDF2-HMAC-SHA256 hash (random 16-byte salt) is stored, in the Keychain,
///   device-only and never synced or backed up.
/// - A 6-digit PIN has 10^6 values, so key stretching alone can't stop an offline brute
///   force of an extracted Keychain item (that requires a jailbroken/forensically imaged
///   device). The guessing bound is enforced on-device instead: every attempt is counted
///   *before* it is checked, delays escalate, and after `maxTotalFailures` the PIN is
///   disabled outright — at most 10 guesses, i.e. a 0.001% chance for a random attacker.
/// - Attempt state also lives in the Keychain, so it can't be cleared from app Settings.
///   If that state can't be written, verification fails closed.
///
/// Explicitly `nonisolated`: hashing runs on a detached task (see `AppLockManager.verifyPIN`).
/// The class holds only constants and a `Sendable` store; concurrent checks are prevented by
/// `AppLockManager.isVerifyingPIN`, and enrolment only happens while the app is unlocked.
nonisolated final class AppPINManager: @unchecked Sendable {
    static let pinLength = 6
    static let attemptsBeforeFirstDelay = 3
    static let maxTotalFailures = 10

    private let store: SecretStore
    private let verifierAccount = "pinVerifier"
    private let stateAccount = "pinAttemptState"
    private let iterations: UInt32 = 200_000
    private let saltLength = 16
    private let hashLength = 32

    init(store: SecretStore = KeychainStore(service: "WealthOS.AppLock")) {
        self.store = store
    }

    var isEnrolled: Bool { loadVerifier() != nil }
    var isDisabledByFailures: Bool { (loadState()?.failedAttempts ?? 0) >= Self.maxTotalFailures }
    var isUsable: Bool { isEnrolled && !isDisabledByFailures }

    static func isValidFormat(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Replaces any existing PIN and clears its attempt history. Callers must have
    /// re-authenticated the device owner first (see `AppLockManager.reauthorize`).
    func enroll(_ newPIN: String) throws {
        guard Self.isValidFormat(newPIN) else { throw PINError.invalidFormat }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PINError.keyDerivationFailed }
        let hash = try Self.deriveHash(pin: newPIN, salt: salt, iterations: iterations, length: hashLength)
        guard saveState(AttemptState()) else { throw PINError.storageFailed }
        do {
            try store.save((salt + hash).base64EncodedString(), account: verifierAccount)
        } catch {
            throw PINError.storageFailed
        }
    }

    /// Removes only the PIN verifier and its attempt counters — never financial data.
    ///
    /// The verifier goes first: if that fails, the PIN stays fully active *with* its attempt
    /// counter (deleting the counter first could reset the brute-force limit on a PIN that
    /// then remains enrolled) and `PINError.removalFailed` is thrown. Once the verifier is gone
    /// the PIN is off; a counter that can't be deleted is harmless because `enroll` resets it.
    func disable() throws {
        do {
            try store.delete(verifierAccount)
        } catch {
            throw PINError.removalFailed
        }
        try? store.delete(stateAccount)
    }

    func verify(_ candidate: String, now: Date = .now) -> PINVerificationResult {
        // Fail closed: an unreadable verifier or attempt counter (device locked, Keychain error,
        // corrupt record) is never treated as "no PIN" or "no failed attempts".
        switch store.lookup(verifierAccount) {
        case .notFound: return .notEnrolled
        case .locked, .failure: return .unavailable
        case .found: break
        }
        guard let verifier = loadVerifier(), let state = loadState() else { return .unavailable }
        guard state.failedAttempts < Self.maxTotalFailures else { return .disabled }

        let nowSeconds = now.timeIntervalSince1970
        if state.lockedUntil > nowSeconds {
            // Clamp so moving the clock backwards can't create an absurdly long wait.
            let cap = Self.lockoutDuration(forFailedAttempts: state.failedAttempts)
            return .lockedOut(retryAfter: min(state.lockedUntil - nowSeconds, cap))
        }

        // Record the attempt as failed *before* checking it, so killing the app mid-check
        // can't yield a free guess. Refuse to check at all if the record can't be written.
        var pending = state
        pending.failedAttempts += 1
        let delay = Self.lockoutDuration(forFailedAttempts: pending.failedAttempts)
        pending.lockedUntil = delay > 0 ? nowSeconds + delay : 0
        guard saveState(pending) else {
            return .lockedOut(retryAfter: Self.lockoutDuration(forFailedAttempts: Self.attemptsBeforeFirstDelay))
        }

        let matches = Self.isValidFormat(candidate)
            && (try? Self.deriveHash(pin: candidate, salt: verifier.salt, iterations: iterations, length: hashLength))
                .map { Self.constantTimeEquals($0, verifier.hash) } == true
        if matches {
            _ = saveState(AttemptState())
            return .success
        }
        if pending.failedAttempts >= Self.maxTotalFailures { return .disabled }
        if delay > 0 { return .lockedOut(retryAfter: delay) }
        return .incorrect(remainingBeforeLockout: max(0, Self.attemptsBeforeFirstDelay - pending.failedAttempts))
    }

    /// Seconds until the next attempt is allowed, or nil. Reads state only; never an attempt.
    func lockoutRemaining(now: Date = .now) -> TimeInterval? {
        guard let state = loadState() else { return nil }
        let remaining = state.lockedUntil - now.timeIntervalSince1970
        guard remaining > 0 else { return nil }
        return min(remaining, Self.lockoutDuration(forFailedAttempts: state.failedAttempts))
    }

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

    private func loadVerifier() -> (salt: Data, hash: Data)? {
        guard let raw = store.read(verifierAccount), let data = Data(base64Encoded: raw),
              data.count == saltLength + hashLength else { return nil }
        return (Data(data.prefix(saltLength)), Data(data.suffix(hashLength)))
    }

    /// nil when the counter exists but can't be read or decoded. Only a counter that genuinely
    /// doesn't exist starts fresh — a Keychain error must never reset the brute-force limit.
    private func loadState() -> AttemptState? {
        switch store.lookup(stateAccount) {
        case .notFound: return AttemptState()
        case .locked, .failure: return nil
        case .found(let raw):
            guard let data = Data(base64Encoded: raw) else { return nil }
            return try? JSONDecoder().decode(AttemptState.self, from: data)
        }
    }

    private func saveState(_ state: AttemptState) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return (try? store.save(data.base64EncodedString(), account: stateAccount)) != nil
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
