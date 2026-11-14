import Foundation
import CryptoKit
import CommonCrypto

nonisolated enum BackupCryptoError: LocalizedError, Equatable {
    case notABackup
    case unsupportedVersion
    case wrongPasswordOrCorrupted
    case keyDerivationFailed
    case passwordTooShort

    var errorDescription: String? {
        switch self {
        case .notABackup: "This file is not a WealthOS backup."
        case .unsupportedVersion: "This backup was created by a newer version of WealthOS."
        case .wrongPasswordOrCorrupted: "The password is incorrect or the backup file is damaged."
        case .keyDerivationFailed: "Could not derive the encryption key."
        case .passwordTooShort: "Use a backup password with at least 8 characters."
        }
    }
}

/// Encrypted backup container. Uses only standard primitives:
/// - Key derivation: PBKDF2-HMAC-SHA256 (CommonCrypto) with a random 16-byte salt.
/// - Encryption: AES-256-GCM (CryptoKit), authenticated; the header is bound as associated data.
///
/// File layout: "WOSB" | version (1 byte) | iterations (UInt32 BE) | salt (16) | AES-GCM combined box.
nonisolated enum BackupCrypto {
    static let magic = Data("WOSB".utf8)
    static let version: UInt8 = 1
    static let defaultIterations: UInt32 = 600_000
    static let minimumPasswordLength = 8
    static let headerLength = 4 + 1 + 4 + 16

    static func encrypt(_ plaintext: Data, password: String, iterations: UInt32 = defaultIterations) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw BackupCryptoError.passwordTooShort }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupCryptoError.keyDerivationFailed }

        var header = magic
        header.append(version)
        withUnsafeBytes(of: iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(salt)

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw BackupCryptoError.keyDerivationFailed }
        return header + combined
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard data.count > headerLength + 28, data.prefix(4) == magic else { throw BackupCryptoError.notABackup }
        let bytes = [UInt8](data)
        guard bytes[4] == version else { throw BackupCryptoError.unsupportedVersion }
        let iterations = UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 8 | UInt32(bytes[8])
        // Bound the work factor so a crafted file can't freeze the device.
        guard (10_000...10_000_000).contains(iterations) else { throw BackupCryptoError.notABackup }
        let header = Data(bytes[0..<headerLength])
        let salt = Data(bytes[9..<headerLength])
        let body = Data(bytes[headerLength...])

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: body)
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw BackupCryptoError.wrongPasswordOrCorrupted
        }
    }

    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: kCCKeySizeAES256)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES256)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupCryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    @concurrent
    static func encryptInBackground(_ plaintext: Data, password: String) async throws -> Data {
        try encrypt(plaintext, password: password)
    }

    @concurrent
    static func decryptInBackground(_ data: Data, password: String) async throws -> Data {
        try decrypt(data, password: password)
    }
}
