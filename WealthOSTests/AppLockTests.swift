import Foundation
import LocalAuthentication
import Testing
@testable import MyApp

// MARK: - Test doubles (no real Face ID / Keychain is ever touched)

/// Simulates `LAContext` outcomes without touching biometric hardware, as required for
/// automated lock-state tests: success, failure, cancellation, lockout and unavailability
/// are all expressible, and `evaluateCallCount` lets tests assert how many real prompts
/// would have been shown.
final class MockBiometricAuthenticator: BiometricAuthenticating, @unchecked Sendable {
    var canEvaluateBiometrics = true
    var canEvaluateDeviceOwner = true
    var evaluateResult: Result<Bool, Error> = .success(true)
    var evaluateDelayNanoseconds: UInt64 = 0
    private(set) var evaluateCallCount = 0

    func canEvaluate(_ policy: LAPolicy) -> Bool {
        policy == .deviceOwnerAuthenticationWithBiometrics ? canEvaluateBiometrics : canEvaluateDeviceOwner
    }

    func evaluate(_ policy: LAPolicy, reason: String) async throws -> Bool {
        evaluateCallCount += 1
        if evaluateDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: evaluateDelayNanoseconds) }
        return try evaluateResult.get()
    }
}

enum AppLockTestSupport {
    /// `isLockEnabled` reads a shared `UserDefaults.standard` key; tests that depend on it
    /// restore the previous value so they can't leak state into unrelated test runs.
    static func withLockEnabled(_ enabled: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled)
        UserDefaults.standard.set(enabled, forKey: SettingsKey.lockEnabled)
        defer { UserDefaults.standard.set(previous, forKey: SettingsKey.lockEnabled) }
        try await body()
    }
}

// MARK: - Automatic authentication & lock-state transitions

@MainActor
@Suite("App lock — automatic authentication")
struct AppLockAutomaticAuthTests {
    @Test func automaticallyUnlocksOnSuccess() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .success(true)
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = true

        lock.authenticateAutomatically()
        await waitUntil { bio.evaluateCallCount == 1 }

        #expect(bio.evaluateCallCount == 1)
        #expect(lock.isLocked == false)
    }

    @Test func automaticPromptFiresOnlyOncePerLockSession() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.authenticationFailed))
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = true

        lock.authenticateAutomatically()
        await waitUntil { bio.evaluateCallCount == 1 }
        // Still locked (failure, not cancel) — a second automatic trigger (e.g. a spurious
        // scenePhase wobble) must not show a second prompt.
        lock.authenticateAutomatically()
        lock.authenticateAutomatically()
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(bio.evaluateCallCount == 1)
        #expect(lock.isLocked == true)
    }

    @Test func newLockSessionReArmsTheAutomaticPrompt() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .success(true)
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = true
        lock.authenticateAutomatically()
        await waitUntil { bio.evaluateCallCount == 1 }
        #expect(lock.isLocked == false)

        await AppLockTestSupport.withLockEnabled(true) {
            lock.lockIfEnabled()
            #expect(lock.isLocked == true)
            lock.authenticateAutomatically()
            await waitUntil { bio.evaluateCallCount == 2 }
            #expect(bio.evaluateCallCount == 2)
        }
    }

    @Test func cancellationLeavesAppLockedWithoutRetryLoop() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userCancel))
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = true

        let result = await lock.authenticate()

        #expect(result == false)
        #expect(lock.isLocked == true)
        #expect(lock.errorMessage == nil)
    }

    @Test func overlappingAuthenticateCallsDoNotDoubleDrompt() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .success(true)
        bio.evaluateDelayNanoseconds = 50_000_000
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = true

        async let first = lock.authenticate()
        try? await Task.sleep(nanoseconds: 5_000_000)
        let second = await lock.authenticate()
        let firstResult = await first

        #expect(second == false, "a second concurrent call must be rejected while one is in flight")
        #expect(firstResult == true)
        #expect(bio.evaluateCallCount == 1)
    }

    @Test func lockIfEnabledResetsFailureStateForTheNewSession() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.authenticationFailed))
        let pin = AppPINManager(store: MemorySecrets())
        try! pin.enroll("123456")
        let lock = AppLockManager(biometrics: bio, pin: pin)
        lock.isLocked = true

        _ = await lock.authenticate()
        _ = await lock.authenticate()
        _ = await lock.authenticate()
        #expect(lock.showPINEntry == true, "three biometric failures should offer the PIN fallback")

        await AppLockTestSupport.withLockEnabled(true) {
            lock.lockIfEnabled()
            #expect(lock.showPINEntry == false, "a fresh lock session starts with Face ID, not the PIN screen")
        }
    }

    @Test func biometricUnavailableWithPINEnrolledOffersPINImmediately() async {
        let bio = MockBiometricAuthenticator()
        bio.canEvaluateBiometrics = false
        bio.canEvaluateDeviceOwner = true
        bio.evaluateResult = .success(true)
        let pin = AppPINManager(store: MemorySecrets())
        try! pin.enroll("654321")
        let lock = AppLockManager(biometrics: bio, pin: pin)
        lock.isLocked = true

        // No biometrics available, but deviceOwnerAuthentication (passcode) still succeeds via
        // evaluate — this exercises the fallback policy selection, not the PIN path itself.
        let result = await lock.authenticate()
        #expect(result == true)
        #expect(lock.isLocked == false)
    }

    @Test func noPasscodeAndNoPINLeavesLockDisabledWithGuidance() async {
        let bio = MockBiometricAuthenticator()
        bio.canEvaluateBiometrics = false
        bio.canEvaluateDeviceOwner = false
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = true

        let result = await lock.authenticate()

        #expect(result == false)
        #expect(lock.isLocked == false)
        #expect(lock.errorMessage != nil)
    }

    /// Polls a condition instead of a fixed sleep, since `authenticateAutomatically()`
    /// dispatches its `Task` without the caller awaiting it directly.
    private func waitUntil(timeout: UInt64 = 1_000_000_000, _ condition: @escaping () -> Bool) async {
        let step: UInt64 = 5_000_000
        var waited: UInt64 = 0
        while !condition(), waited < timeout {
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
    }
}

// MARK: - PIN fallback

@MainActor
@Suite("App lock — PIN fallback")
struct AppLockPINTests {
    @Test func manualPINRequestRequiresEnrollment() {
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: AppPINManager(store: MemorySecrets()))
        lock.requestPINEntry()
        #expect(lock.showPINEntry == false)
    }

    @Test func manualPINRequestShowsEntryWhenEnrolled() throws {
        let pin = AppPINManager(store: MemorySecrets())
        try pin.enroll("112233")
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: pin)
        lock.requestPINEntry()
        #expect(lock.showPINEntry == true)
        lock.cancelPINEntry()
        #expect(lock.showPINEntry == false)
    }

    @Test func correctPINUnlocksTheApp() throws {
        let pin = AppPINManager(store: MemorySecrets())
        try pin.enroll("778899")
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: pin)
        lock.isLocked = true

        let result = lock.verifyPIN("778899")

        #expect(result == .success)
        #expect(lock.isLocked == false)
    }

    @Test func wrongPINKeepsTheAppLocked() throws {
        let pin = AppPINManager(store: MemorySecrets())
        try pin.enroll("778899")
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: pin)
        lock.isLocked = true

        let result = lock.verifyPIN("000000")

        if case .incorrect = result {} else { Issue.record("expected .incorrect, got \(result)") }
        #expect(lock.isLocked == true)
    }
}

// MARK: - AppPINManager: storage, rate limiting and recovery

@Suite("AppPINManager")
struct AppPINManagerTests {
    @Test func enrollRejectsNonSixDigitInput() {
        let manager = AppPINManager(store: MemorySecrets())
        for bad in ["12345", "1234567", "12345a", "", "abcdef"] {
            #expect(throws: PINError.self) { try manager.enroll(bad) }
        }
        #expect(manager.isEnrolled == false)
    }

    @Test func verifyBeforeEnrollmentReportsNotEnrolled() {
        let manager = AppPINManager(store: MemorySecrets())
        #expect(manager.verify("123456") == .notEnrolled)
    }

    @Test func correctPINVerifiesSuccessfully() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("483920")
        #expect(manager.verify("483920") == .success)
    }

    @Test func pinIsNeverStoredInPlaintext() throws {
        let secrets = MemorySecrets()
        let manager = AppPINManager(store: secrets)
        try manager.enroll("135790")
        for value in secrets.values.values {
            #expect(!value.contains("135790"))
        }
    }

    @Test func wrongPINIncrementsFailureCountBeforeLockout() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")

        guard case .incorrect(let remaining1) = manager.verify("111111") else {
            Issue.record("expected .incorrect"); return
        }
        #expect(remaining1 == 2)
        guard case .incorrect(let remaining2) = manager.verify("111111") else {
            Issue.record("expected .incorrect"); return
        }
        #expect(remaining2 == 1)
    }

    @Test func thirdConsecutiveFailureTriggersProgressiveLockout() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        _ = manager.verify("111111")
        _ = manager.verify("111111")

        guard case .lockedOut(let retryAfter) = manager.verify("111111") else {
            Issue.record("expected .lockedOut on the third consecutive failure"); return
        }
        #expect(retryAfter > 0)

        // A correct PIN submitted during the lockout window must still be rejected —
        // the lock isn't just a UI hint, it's enforced by AppPINManager itself.
        guard case .lockedOut = manager.verify("246810") else {
            Issue.record("expected the correct PIN to still be locked out"); return
        }
    }

    @Test func lockoutDurationEscalatesWithRepeatedFailures() {
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 1) == 0)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 2) == 0)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 3) == 30)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 4) == 60)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 5) == 300)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 9) == 900)
    }

    @Test func successfulVerifyResetsTheFailureCounter() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        _ = manager.verify("111111")
        #expect(manager.verify("246810") == .success)

        guard case .incorrect(let remaining) = manager.verify("111111") else {
            Issue.record("expected .incorrect"); return
        }
        #expect(remaining == 2, "the counter should have reset after the earlier success")
    }

    @Test func disableRemovesEnrollmentAndAttemptState() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        _ = manager.verify("000000")

        manager.disable()

        #expect(manager.isEnrolled == false)
        #expect(manager.verify("246810") == .notEnrolled)
    }

    @Test func enrollingAgainReplacesThePreviousPINAndAttemptState() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("111222")
        _ = manager.verify("000000")

        try manager.enroll("333444")

        #expect(manager.verify("111222") == .incorrect(remainingBeforeLockout: 2))
        #expect(manager.verify("333444") == .success)
    }
}
