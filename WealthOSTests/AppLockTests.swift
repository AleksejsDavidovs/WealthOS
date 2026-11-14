import Foundation
import LocalAuthentication
import SwiftUI
import Testing
import UIKit
@testable import MyApp

// MARK: - Test doubles (no real Face ID or real Keychain item is ever touched)

/// Simulates `LAContext` outcomes: success, failure, cancellation, fallback, lockout and
/// unavailability. Records every prompt so tests can assert how many would have been shown.
final class MockBiometricAuthenticator: BiometricAuthenticating, @unchecked Sendable {
    var canEvaluateBiometrics = true
    var canEvaluateDeviceOwner = true
    var evaluateResult: Result<Bool, Error> = .success(true)
    var evaluateDelayNanoseconds: UInt64 = 0
    private(set) var prompts: [(policy: LAPolicy, fallbackTitle: String?)] = []
    var evaluateCallCount: Int { prompts.count }

    func canEvaluate(_ policy: LAPolicy) -> Bool {
        policy == .deviceOwnerAuthenticationWithBiometrics ? canEvaluateBiometrics : canEvaluateDeviceOwner
    }

    func evaluate(_ policy: LAPolicy, reason: String, fallbackTitle: String?) async throws -> Bool {
        prompts.append((policy, fallbackTitle))
        if evaluateDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: evaluateDelayNanoseconds) }
        return try evaluateResult.get()
    }
}

/// Keychain stand-in whose writes to one account can be made to fail.
final class FailingSecrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var failingAccount: String?
    func lookup(_ account: String) -> SecretLookup { values[account].map { .found($0) } ?? .notFound }
    func save(_ value: String, account: String) throws {
        if account == failingAccount { throw KeychainError.status(errSecIO) }
        values[account] = value
    }
    func delete(_ account: String) throws { values[account] = nil }
}

enum AppLockTestSupport {
    /// `isLockEnabled` reads a shared `UserDefaults.standard` key (in the simulator's test-host
    /// container, never the device). The previous value is always restored.
    @MainActor
    static func withLockEnabled(_ enabled: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.bool(forKey: SettingsKey.lockEnabled)
        UserDefaults.standard.set(enabled, forKey: SettingsKey.lockEnabled)
        defer { UserDefaults.standard.set(previous, forKey: SettingsKey.lockEnabled) }
        try await body()
    }

    @MainActor
    static func lockedManager(_ bio: MockBiometricAuthenticator, pin: String? = nil) throws -> AppLockManager {
        let pinManager = AppPINManager(store: MemorySecrets())
        if let pin { try pinManager.enroll(pin) }
        let lock = AppLockManager(biometrics: bio, pin: pinManager)
        lock.isLocked = true
        return lock
    }

    /// `authenticateAutomatically()` launches its own Task; poll instead of a fixed sleep.
    @MainActor
    static func waitUntil(timeout: UInt64 = 1_000_000_000, _ condition: () -> Bool) async {
        var waited: UInt64 = 0
        while !condition(), waited < timeout {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5_000_000
        }
    }
}

/// Parent suite: `.serialized` here also serializes every nested suite, so tests sharing the
/// `lockEnabled` default and the host app's window scene never run concurrently.
@MainActor
@Suite("App lock", .serialized)
enum AppLockSuites {

// MARK: - Automatic Face ID & lock-state transitions

@MainActor
@Suite("Automatic authentication & lifecycle")
struct AppLockAutomaticAuthTests {
    @Test func automaticallyUnlocksOnSuccess() async throws {
        let bio = MockBiometricAuthenticator()
        let lock = try AppLockTestSupport.lockedManager(bio)

        lock.authenticateAutomatically()
        await AppLockTestSupport.waitUntil { !lock.isLocked }

        #expect(bio.evaluateCallCount == 1)
        #expect(lock.isLocked == false)
    }

    @Test func automaticPromptFiresOnlyOncePerLockSession() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.authenticationFailed))
        let lock = try AppLockTestSupport.lockedManager(bio)

        lock.authenticateAutomatically()
        await AppLockTestSupport.waitUntil { bio.evaluateCallCount == 1 && !lock.isAuthenticating }
        // The Face ID sheet itself bounces scenePhase inactive→active; those re-triggers must not re-prompt.
        lock.authenticateAutomatically()
        lock.authenticateAutomatically()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(bio.evaluateCallCount == 1)
        #expect(lock.isLocked == true)
    }

    @Test func cancellingLeavesAppLockedAndDoesNotRePrompt() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userCancel))
        let lock = try AppLockTestSupport.lockedManager(bio)

        lock.authenticateAutomatically()
        await AppLockTestSupport.waitUntil { bio.evaluateCallCount == 1 && !lock.isAuthenticating }
        lock.authenticateAutomatically()
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(lock.isLocked == true)
        #expect(lock.errorMessage == nil)
        #expect(bio.evaluateCallCount == 1)
    }

    @Test func manualRetryStillWorksAfterCancel() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userCancel))
        let lock = try AppLockTestSupport.lockedManager(bio)
        _ = await lock.authenticate()

        bio.evaluateResult = .success(true)
        let unlocked = await lock.authenticate()

        #expect(unlocked)
        #expect(lock.isLocked == false)
    }

    @Test func backgroundingStartsANewSessionWithOneFreshPrompt() async throws {
        let bio = MockBiometricAuthenticator()
        let lock = try AppLockTestSupport.lockedManager(bio)
        lock.authenticateAutomatically()
        await AppLockTestSupport.waitUntil { !lock.isLocked }

        await AppLockTestSupport.withLockEnabled(true) {
            lock.lockIfEnabled()
            #expect(lock.isLocked == true)
            lock.authenticateAutomatically()
            await AppLockTestSupport.waitUntil { bio.evaluateCallCount == 2 }
        }
        #expect(bio.evaluateCallCount == 2)
    }

    @Test func lockIfEnabledDoesNothingWhenLockIsOff() async {
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: AppPINManager(store: MemorySecrets()))
        lock.isLocked = false
        await AppLockTestSupport.withLockEnabled(false) {
            lock.lockIfEnabled()
        }
        #expect(lock.isLocked == false)
    }

    @Test func overlappingAuthenticateCallsShowOnlyOnePrompt() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateDelayNanoseconds = 80_000_000
        let lock = try AppLockTestSupport.lockedManager(bio)

        async let first = lock.authenticate()
        await AppLockTestSupport.waitUntil { lock.isAuthenticating }
        let second = await lock.authenticate()
        let firstResult = await first

        #expect(second == false, "a concurrent call must be rejected while a prompt is on screen")
        #expect(firstResult == true)
        #expect(bio.evaluateCallCount == 1)
    }

    @Test func successFromAPromptStartedBeforeRelockDoesNotUnlockTheNewSession() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateDelayNanoseconds = 80_000_000
        let lock = try AppLockTestSupport.lockedManager(bio)

        async let result = lock.authenticate()
        await AppLockTestSupport.waitUntil { lock.isAuthenticating }
        await AppLockTestSupport.withLockEnabled(true) {
            lock.lockIfEnabled()   // app backgrounded while the old prompt was finishing
        }
        let unlocked = await result

        #expect(unlocked == false)
        #expect(lock.isLocked == true)
    }

    @Test func withoutPINDevicePasscodeFallbackIsKept() async throws {
        let bio = MockBiometricAuthenticator()
        let lock = try AppLockTestSupport.lockedManager(bio)

        _ = await lock.authenticate()

        #expect(bio.prompts.first?.policy == .deviceOwnerAuthentication,
                "without an app PIN, the system prompt must still offer the device passcode")
    }

    @Test func withPINFaceIDPromptOffersUsePIN() async throws {
        let bio = MockBiometricAuthenticator()
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "246810")

        _ = await lock.authenticate()

        #expect(bio.prompts.first?.policy == .deviceOwnerAuthenticationWithBiometrics)
        #expect(bio.prompts.first?.fallbackTitle == "Use PIN")
    }

    @Test func noPasscodeAndNoPINCannotEnforceLock() async throws {
        let bio = MockBiometricAuthenticator()
        bio.canEvaluateBiometrics = false
        bio.canEvaluateDeviceOwner = false
        let lock = try AppLockTestSupport.lockedManager(bio)

        let result = await lock.authenticate()

        #expect(result == false)
        #expect(lock.isLocked == false)
        #expect(lock.errorMessage != nil)
        #expect(bio.evaluateCallCount == 0)
    }

    @Test func noPasscodeButPINEnrolledStaysLockedAndAsksForPIN() async throws {
        let bio = MockBiometricAuthenticator()
        bio.canEvaluateBiometrics = false
        bio.canEvaluateDeviceOwner = false
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "246810")

        _ = await lock.authenticate()

        #expect(lock.isLocked == true)
        #expect(lock.showPINEntry == true)
    }
}

// MARK: - PIN fallback on the lock screen

@MainActor
@Suite("App lock — PIN fallback")
struct AppLockPINFallbackTests {
    @Test func threeFailedFaceIDPromptsOfferThePIN() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.authenticationFailed))
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "246810")

        _ = await lock.authenticate()
        _ = await lock.authenticate()
        #expect(lock.showPINEntry == false)
        _ = await lock.authenticate()
        #expect(lock.showPINEntry == true)
        #expect(lock.isLocked == true)
    }

    @Test func tappingUsePINInTheFaceIDPromptOpensPINEntry() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userFallback))
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "246810")

        _ = await lock.authenticate()

        #expect(lock.showPINEntry == true)
    }

    @Test func biometryLockoutOffersThePIN() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.biometryLockout))
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "246810")

        _ = await lock.authenticate()

        #expect(lock.showPINEntry == true)
        #expect(lock.isLocked == true)
    }

    @Test func newLockSessionStartsWithFaceIDNotThePINScreen() async throws {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userFallback))
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "246810")
        _ = await lock.authenticate()
        #expect(lock.showPINEntry == true)

        await AppLockTestSupport.withLockEnabled(true) { lock.lockIfEnabled() }

        #expect(lock.showPINEntry == false)
        #expect(lock.biometricFailureCount == 0)
    }

    @Test func manualPINRequestRequiresEnrollment() throws {
        let lock = try AppLockTestSupport.lockedManager(MockBiometricAuthenticator())
        lock.requestPINEntry()
        #expect(lock.showPINEntry == false)
    }

    @Test func correctPINUnlocks() async throws {
        let lock = try AppLockTestSupport.lockedManager(MockBiometricAuthenticator(), pin: "778899")
        #expect(await lock.verifyPIN("778899") == .success)
        #expect(lock.isLocked == false)
    }

    @Test func wrongPINKeepsTheAppLocked() async throws {
        let lock = try AppLockTestSupport.lockedManager(MockBiometricAuthenticator(), pin: "778899")
        #expect(await lock.verifyPIN("000000") == .incorrect(remainingBeforeLockout: 2))
        #expect(lock.isLocked == true)
    }

    @Test func pinIsIgnoredWhenTheAppIsNotLocked() async throws {
        let lock = try AppLockTestSupport.lockedManager(MockBiometricAuthenticator(), pin: "778899")
        lock.isLocked = false
        #expect(await lock.verifyPIN("000000") == nil)
        #expect(lock.pinLockoutRemaining() == nil, "an ignored check must not count as an attempt")
    }

    @Test func overlappingPINChecksAreRejected() async throws {
        let lock = try AppLockTestSupport.lockedManager(MockBiometricAuthenticator(), pin: "778899")

        async let first = lock.verifyPIN("000000")
        await AppLockTestSupport.waitUntil { lock.isVerifyingPIN }
        let second = await lock.verifyPIN("000000")
        let firstResult = await first

        #expect(second == nil, "a second check while one runs would race on the attempt counter")
        #expect(firstResult == .incorrect(remainingBeforeLockout: 2))
    }

    /// The reported bug: with a PIN set and Face ID unavailable (lockout, covered, not
    /// enrolled), unlocking fell through to Apple's passcode sheet instead of the PIN pad.
    @Test func faceIDUnavailableWithPINGoesToPINPadNotSystemPasscode() async throws {
        let bio = MockBiometricAuthenticator()
        bio.canEvaluateBiometrics = false
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "778899")

        let unlocked = await lock.authenticate()

        #expect(unlocked == false)
        #expect(lock.showPINEntry == true)
        #expect(bio.evaluateCallCount == 0, "no system prompt — the WealthOS PIN is the fallback")
        #expect(lock.isLocked == true)
    }

    @Test func pinDisabledByFailuresFallsBackToSystemAuthentication() async throws {
        let bio = MockBiometricAuthenticator()
        let pin = AppPINManager(store: MemorySecrets())
        try pin.enroll("778899")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<AppPINManager.maxTotalFailures { _ = pin.verify("000000", now: clock); clock.addTimeInterval(3_600) }
        let lock = AppLockManager(biometrics: bio, pin: pin)
        lock.isLocked = true

        _ = await lock.authenticate()

        #expect(bio.prompts.last?.policy == .deviceOwnerAuthentication)
    }

    @Test func devicePasscodeRecoveryUnlocksWhenPINIsForgotten() async throws {
        let bio = MockBiometricAuthenticator()
        let lock = try AppLockTestSupport.lockedManager(bio, pin: "778899")
        lock.requestPINEntry()

        let unlocked = await lock.authenticateWithDevicePasscode()

        #expect(unlocked)
        #expect(lock.isLocked == false)
        #expect(bio.prompts.last?.policy == .deviceOwnerAuthentication)
    }
}

// MARK: - Authorization for security-setting changes

@MainActor
@Suite("App lock — security settings require re-authentication", .serialized)
struct AppLockAuthorizationTests {
    @Test func pinEnabledFlagIsObservableAcrossEnrollAndDisable() async throws {
        let lock = AppLockManager(biometrics: MockBiometricAuthenticator(), pin: AppPINManager(store: MemorySecrets()))
        #expect(lock.isPINEnabled == false)
        try await lock.enrollPIN("135790")
        #expect(lock.isPINEnabled == true)
        try lock.disablePIN()
        #expect(lock.isPINEnabled == false)
    }

    @Test func reauthorizeFailsWhenOwnerCancels() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userCancel))
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))

        #expect(await lock.reauthorize(reason: "test") == false)
        #expect(bio.prompts.last?.policy == .deviceOwnerAuthentication)
    }

    @Test func turningTheLockOffRequiresAuthentication() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.userCancel))
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))

        await AppLockTestSupport.withLockEnabled(true) {
            let changed = await lock.setLockEnabled(false)
            #expect(changed == false)
            #expect(lock.isLockEnabled == true, "a failed authentication must leave the lock on")
        }
    }

    @Test func turningTheLockOnRequiresAuthentication() async {
        let bio = MockBiometricAuthenticator()
        bio.evaluateResult = .failure(LAError(.authenticationFailed))
        let lock = AppLockManager(biometrics: bio, pin: AppPINManager(store: MemorySecrets()))

        await AppLockTestSupport.withLockEnabled(false) {
            #expect(await lock.setLockEnabled(true) == false)
            #expect(lock.isLockEnabled == false)
        }
    }
}

// MARK: - Modal security boundary

/// The overlay must sit in its own window above the main window, where every sheet,
/// popover and dialog is presented, and must block the main window while shown.
@MainActor
@Suite("Secure overlay window", .serialized)
struct SecureOverlayWindowTests {
    private func makeMainWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        return window
    }

    @Test func overlayIsAboveTheMainWindowAndBlocksIt() throws {
        let main = try makeMainWindow()
        let overlay = SecureOverlayWindow()
        overlay.attach(using: main)

        overlay.show { Color.black }
        defer { overlay.hide() }

        #expect(overlay.isVisible)
        #expect(try #require(overlay.windowLevel) > main.windowLevel)
        #expect(main.isUserInteractionEnabled == false)
        #expect(main.accessibilityElementsHidden == true)
    }

    @Test func coverAppearsInstantlyWithoutFadeIn() throws {
        let overlay = SecureOverlayWindow()
        overlay.attach(using: try makeMainWindow())

        overlay.show { Color.black }
        defer { overlay.hide() }

        // Visible at full opacity synchronously — before any animation could run — so an
        // app-switcher snapshot can't capture a half-transparent cover.
        #expect(overlay.isVisible)
    }

    @Test func relockDuringUnlockFadeKeepsTheCoverUp() async throws {
        let main = try makeMainWindow()
        let overlay = SecureOverlayWindow()
        overlay.attach(using: main)
        overlay.show { Color.black }

        overlay.hide()                 // unlock starts a 0.25 s fade-out…
        overlay.show { Color.black }   // …and the app relocks before it finishes
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(overlay.isVisible, "the stale fade-out completion must not hide a re-shown cover")
        #expect(main.isUserInteractionEnabled == false)
        overlay.hide()
    }

    @Test func hidingRestoresTheMainWindow() async throws {
        let main = try makeMainWindow()
        let overlay = SecureOverlayWindow()
        overlay.attach(using: main)
        overlay.show { Color.black }

        overlay.hide()
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(overlay.isVisible == false)
        #expect(main.isUserInteractionEnabled == true)
        #expect(main.accessibilityElementsHidden == false)
    }
}

} // AppLockSuites

// MARK: - AppPINManager: storage, rate limiting and recovery

@Suite("AppPINManager")
struct AppPINManagerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func enrollRejectsAnythingButSixDigits() {
        let manager = AppPINManager(store: MemorySecrets())
        for bad in ["12345", "1234567", "12345a", "", "abcdef", "１２３４５６"] {
            #expect(throws: PINError.self) { try manager.enroll(bad) }
        }
        #expect(manager.isEnrolled == false)
    }

    @Test func verifyBeforeEnrollmentReportsNotEnrolled() {
        #expect(AppPINManager(store: MemorySecrets()).verify("123456") == .notEnrolled)
    }

    @Test func correctPINVerifies() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("483920")
        #expect(manager.verify("483920") == .success)
    }

    @Test func pinIsNeverStoredInPlaintextAndIsSalted() throws {
        let a = MemorySecrets(), b = MemorySecrets()
        try AppPINManager(store: a).enroll("135790")
        try AppPINManager(store: b).enroll("135790")
        for value in a.values.values { #expect(!value.contains("135790")) }
        #expect(a.values["pinVerifier"] != b.values["pinVerifier"], "same PIN must yield different verifiers")
    }

    @Test func firstTwoFailuresReportRemainingAttempts() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        #expect(manager.verify("111111", now: start) == .incorrect(remainingBeforeLockout: 2))
        #expect(manager.verify("111111", now: start) == .incorrect(remainingBeforeLockout: 1))
    }

    @Test func thirdFailureLocksOutEvenForTheCorrectPIN() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        _ = manager.verify("111111", now: start)
        _ = manager.verify("111111", now: start)

        #expect(manager.verify("111111", now: start) == .lockedOut(retryAfter: 30))
        #expect(manager.verify("246810", now: start.addingTimeInterval(10)) == .lockedOut(retryAfter: 20))
    }

    @Test func lockoutExpiresAfterTheDelay() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        for _ in 0..<3 { _ = manager.verify("111111", now: start) }

        #expect(manager.verify("246810", now: start.addingTimeInterval(31)) == .success)
    }

    @Test func delaysEscalate() {
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 2) == 0)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 3) == 30)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 4) == 60)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 5) == 300)
        #expect(AppPINManager.lockoutDuration(forFailedAttempts: 9) == 900)
    }

    @Test func tenTotalFailuresDisableThePINPermanently() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        var clock = start
        var last = PINVerificationResult.notEnrolled
        for _ in 0..<AppPINManager.maxTotalFailures {
            last = manager.verify("111111", now: clock)
            clock.addTimeInterval(3_600)   // even waiting out (or skipping) every delay
        }

        #expect(last == .disabled)
        #expect(manager.verify("246810", now: clock) == .disabled, "the correct PIN must no longer work")
        #expect(manager.isUsable == false)
        #expect(manager.isEnrolled == true)
    }

    @Test func reEnrollingAfterDisableRestoresThePIN() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        var clock = start
        for _ in 0..<AppPINManager.maxTotalFailures {
            _ = manager.verify("111111", now: clock); clock.addTimeInterval(3_600)
        }

        try manager.enroll("975310")

        #expect(manager.verify("975310", now: clock) == .success)
    }

    @Test func movingTheClockBackwardsCannotInflateTheLockout() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        for _ in 0..<3 { _ = manager.verify("111111", now: start) }

        let result = manager.verify("246810", now: start.addingTimeInterval(-86_400 * 365))

        #expect(result == .lockedOut(retryAfter: 30))
    }

    @Test func successResetsTheFailureCounter() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        _ = manager.verify("111111", now: start)
        #expect(manager.verify("246810", now: start) == .success)
        #expect(manager.verify("111111", now: start) == .incorrect(remainingBeforeLockout: 2))
    }

    @Test func failsClosedWhenAttemptStateCannotBeRecorded() throws {
        let secrets = FailingSecrets()
        let manager = AppPINManager(store: secrets)
        try manager.enroll("246810")
        secrets.failingAccount = "pinAttemptState"

        let result = manager.verify("246810", now: start)

        if case .lockedOut = result {} else { Issue.record("expected fail-closed .lockedOut, got \(result)") }
    }

    @Test func lockoutRemainingCountsDownAndIsReadOnly() throws {
        let manager = AppPINManager(store: MemorySecrets())
        try manager.enroll("246810")
        #expect(manager.lockoutRemaining(now: start) == nil)
        for _ in 0..<3 { _ = manager.verify("111111", now: start) }

        // Polling the countdown every second must never count as a guess.
        for second in 0..<20 { _ = manager.lockoutRemaining(now: start.addingTimeInterval(Double(second))) }
        #expect(manager.lockoutRemaining(now: start.addingTimeInterval(12)) == 18)
        #expect(manager.lockoutRemaining(now: start.addingTimeInterval(31)) == nil)
        #expect(manager.verify("111111", now: start.addingTimeInterval(31)) == .lockedOut(retryAfter: 60),
                "fourth failure → next step, proving polling added no attempts")
    }

    @Test func countdownTextFormatsMinutesAndSeconds() {
        #expect((27.2 as TimeInterval).countdownText == "0:28")
        #expect((300 as TimeInterval).countdownText == "5:00")
    }

    @Test func disableRemovesOnlyPINData() throws {
        let secrets = MemorySecrets()
        secrets.values["unrelated"] = "keep"
        let manager = AppPINManager(store: secrets)
        try manager.enroll("246810")

        try manager.disable()

        #expect(manager.isEnrolled == false)
        #expect(manager.verify("246810") == .notEnrolled)
        #expect(secrets.values["unrelated"] == "keep")
    }
}
