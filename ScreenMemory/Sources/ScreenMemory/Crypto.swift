import Foundation
import CryptoKit

/// At-rest encryption of stored screen text (AES-GCM, 256-bit).
/// The key lives in the macOS Keychain; if that's unavailable (unsigned CLI / headless),
/// it falls back to a 0600 key file so the pipeline still encrypts.
struct Crypto {
    private let key: SymmetricKey

    init() {
        self.key = Crypto.loadOrCreateKey()
    }

    func encrypt(_ text: String) -> Data {
        let box = try! AES.GCM.seal(Data(text.utf8), using: key)
        return box.combined!          // nonce || ciphertext || tag
    }

    func decrypt(_ data: Data) -> String {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key),
              let s = String(data: plain, encoding: .utf8)
        else { return "<decrypt failed>" }
        return s
    }

    // MARK: - Key management

    private static let keyFile = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.key")

    // Key lives in a 0600 file in the home dir. (Keychain was avoided on purpose:
    // an ad-hoc-signed app's signature changes every rebuild, so the Keychain ACL
    // no longer matches and macOS re-prompts for the password on every launch.)
    private static func loadOrCreateKey() -> SymmetricKey {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: keyFile)), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try? raw.write(to: URL(fileURLWithPath: keyFile))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile)
        return key
    }
}
