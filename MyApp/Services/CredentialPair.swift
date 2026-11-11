import Foundation

/// What is known about a provider's API key + secret pair in the Keychain.
nonisolated enum CredentialState: Equatable, Sendable {
    /// Neither value exists.
    case missing
    /// Both values exist and the last write completed and was verified.
    case stored
    /// Exactly one value exists (e.g. an earlier deletion half-failed).
    case partial
    /// The device is locked; the items may well exist. Retry once unlocked.
    case locked
    /// The Keychain reported an operational error; the items may well exist.
    case unavailable
    /// A multi-step change (or its rollback) didn't complete verifiably, so the stored key and
    /// secret may not belong together. Never used for syncing until reconnected or disconnected.
    case uncertain
}

/// Failure-explicit handling of one provider's key/secret pair. Every multi-step change is
/// journaled with a non-secret flag (in UserDefaults) that is cleared only after the result
/// has been read back and verified, so a failed rollback — or the app being killed half-way —
/// is reported as `.uncertain` even after a relaunch, instead of as a working connection.
nonisolated struct CredentialPair: @unchecked Sendable {
    typealias Values = (key: String, secret: String)

    let secrets: SecretStore
    let keyAccount: String
    let secretAccount: String
    let defaults: UserDefaults
    /// UserDefaults key of the "write in progress" marker. Holds a Bool, never a secret.
    let journalKey: String

    enum WriteOutcome: Equatable {
        case written
        /// The write failed but the previous pair (or none) was restored and verified.
        case rolledBack
        /// The write failed and the previous state couldn't be restored or verified.
        case uncertain
    }

    func state() -> CredentialState {
        if defaults.bool(forKey: journalKey) { return .uncertain }
        switch (secrets.lookup(keyAccount), secrets.lookup(secretAccount)) {
        case (.found, .found): return .stored
        case (.notFound, .notFound): return .missing
        case (.locked, _), (_, .locked): return .locked
        case (.failure, _), (_, .failure): return .unavailable
        default: return .partial
        }
    }

    /// The pair, only when it is complete and not uncertain.
    func values() -> Values? {
        guard !defaults.bool(forKey: journalKey),
              let key = secrets.lookup(keyAccount).value, let secret = secrets.lookup(secretAccount).value else { return nil }
        return (key, secret)
    }

    /// Reads back both items and compares them with what should be stored (nil = nothing).
    func matches(_ expected: Values?) -> Bool {
        let key = secrets.lookup(keyAccount)
        let secret = secrets.lookup(secretAccount)
        if let expected { return key == .found(expected.key) && secret == .found(expected.secret) }
        return key == .notFound && secret == .notFound
    }

    /// Writes the new pair; on failure restores `previous` (or removes both) and verifies.
    func replace(with new: Values, previous: Values?) -> WriteOutcome {
        defaults.set(true, forKey: journalKey)
        do {
            try secrets.save(new.key, account: keyAccount)
            try secrets.save(new.secret, account: secretAccount)
        } catch {
            return restore(previous) ? .rolledBack : .uncertain
        }
        guard matches(new) else { return restore(previous) ? .rolledBack : .uncertain }
        defaults.removeObject(forKey: journalKey)
        return .written
    }

    /// Puts `previous` back (or removes both). Returns true only if reading both items back
    /// shows exactly the previous state; otherwise the journal stays set and the state reads
    /// as `.uncertain`. Individual write errors are tolerated only when the read-back proves
    /// they didn't matter (e.g. the secret was never overwritten).
    @discardableResult
    func restore(_ previous: Values?) -> Bool {
        defaults.set(true, forKey: journalKey)
        if let previous {
            try? secrets.save(previous.key, account: keyAccount)
            try? secrets.save(previous.secret, account: secretAccount)
        } else {
            try? secrets.delete(keyAccount)
            try? secrets.delete(secretAccount)
        }
        guard matches(previous) else { return false }
        defaults.removeObject(forKey: journalKey)
        return true
    }

    /// Deletes both values. True only when both are verifiably gone (read back as not found);
    /// a verified deletion also resolves an earlier uncertain state.
    func delete() -> Bool {
        try? secrets.delete(keyAccount)
        try? secrets.delete(secretAccount)
        guard matches(nil) else { return false }
        defaults.removeObject(forKey: journalKey)
        return true
    }

    /// Moves both items to the store's protection class. Returns false if a migration failed
    /// (not for missing items or a locked device, which are retried on the next activation).
    func upgradeProtection() -> Bool {
        var ok = true
        for account in [keyAccount, secretAccount] {
            if case .failed = secrets.upgradeProtection(account) { ok = false }
        }
        return ok
    }
}
