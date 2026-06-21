import Foundation
import CommonCrypto

/// The connection auth handshake (spec §3.3). The proof is
/// `AES-128-ECB-PKCS7(auth_key, nonce)[:16]`: PKCS#7 pads the 15-byte nonce
/// with a single `0x01` to one 16-byte block, then ECB-encrypts it.
public enum AuthCrypto {
    /// Compute the 16-byte proof for a 15-byte nonce under a 16-byte key.
    /// Returns nil on bad input lengths or a crypto failure.
    public static func proof(authKey: [UInt8], nonce: [UInt8]) -> [UInt8]? {
        guard authKey.count == 16, nonce.count == 15 else { return nil }

        // PKCS#7 pad the single short block manually (15 -> 16, pad value 0x01),
        // then ECB-encrypt with no further padding.
        var block = nonce
        block.append(0x01)

        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            authKey, authKey.count,
            nil,
            block, block.count,
            &out, out.count,
            &moved
        )
        guard status == kCCSuccess, moved == 16 else { return nil }
        return out
    }

    /// Generate a fresh random 16-byte auth key for onboarding (spec §3.2).
    public static func generateAuthKey() -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        return key
    }
}
