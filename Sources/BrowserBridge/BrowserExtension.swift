import CryptoKit
import Foundation

/// Identity of the companion Chromium extension (`Extension/chromium`).
public enum BrowserExtension {
    /// Name of the native messaging host (`app.palmeet.bridge.json`).
    public static let nativeHostName = "app.palmeet.bridge"

    /// The public `key` in `Extension/chromium/manifest.json` (base64 DER SubjectPublicKeyInfo).
    /// It pins the extension ID for unpacked installs; the private key is not kept anywhere.
    public static let publicKey =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2u48wteqq2LdytLL1cczbGk92Ek3kdIOUCXa/4vmeUmnpztr1Ndo9m9LVUFOoA+S529L4YVzg5hVUwGmv2IU7sgzRHu5xsqmoGYoHbBVhqvMgVD7rOpg4jLeIQfxsp3JLLVv+4YxrO2sBRJA4u1njbaqeYE/Fj8SaAbly+yoUO4P9Lgdr0pAcCOP1gecIaYtE6BREq0hwrPJ1Gpjj8JRra2VBztjsAICG4+pBam1978ySSu2b4W1sUGa7HMBvSrdaEbfIBjPBKZGuIKIdXNcN5LQrV96PtnxjEImx/6CVvfsOqGWvE4wAj9aKN01nSvzIBccanxDGT2d7kxeXdD0JQIDAQAB"

    /// The extension ID derived from `publicKey`.
    public static let defaultExtensionID = "lhchlhlaljhfimjelkfbcmgocleehfin"

    /// Chrome's algorithm: SHA-256 of the DER public key, first 32 hex digits, `0-f` mapped to `a-p`.
    public static func extensionID(publicKeyDER: Data) -> String {
        let digest = SHA256.hash(data: publicKeyDER)
        let alphabet = Array("abcdefghijklmnop")
        var id = ""
        for byte in digest.prefix(16) {
            id.append(alphabet[Int(byte >> 4)])
            id.append(alphabet[Int(byte & 0x0F)])
        }
        return id
    }

    public static func extensionID(publicKeyBase64: String) -> String? {
        guard let der = Data(base64Encoded: publicKeyBase64) else { return nil }
        return extensionID(publicKeyDER: der)
    }

    public static func origin(forExtensionID id: String) -> String { "chrome-extension://\(id)/" }
}
