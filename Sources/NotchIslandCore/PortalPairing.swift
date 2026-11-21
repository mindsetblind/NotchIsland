import CryptoKit
import Foundation
import Security

// Shared by the Mac app and the iOS companion (PortalCompanion compiles this file too, see its project.yml).
//
// Pairing works like Bluetooth's numeric comparison:
// 1. Mac → phone  `hello(mac, nonce)`.
// 2. Phone has no key for this Mac → `pair(device, name, commit = SHA256(phonePub))`.
// 3. Mac → `pairKey(macPub)`; phone → `pairReveal(phonePub)` (the commitment stops a man in the middle
//    from picking keys until the short codes happen to match).
// 4. Both sides run X25519 and show the same 6-digit code; the user compares them. The Mac's user
//    presses «Разрешить», the phone's user «Совпадает» (`confirm`), the Mac answers `paired`, and both
//    keep the 32-byte key derived from the exchange.
// Later connections: phone → `auth(device, name, nonce, proof)`, Mac → `welcome(proof)`: an HMAC over
// both nonces in each direction, so each side knows the other holds the key. Names are only labels.

public enum PortalMessage: Codable, Equatable, Sendable {
    /// Mac → phone, as soon as the session connects.
    case hello(mac: String, nonce: Data)
    /// Phone → Mac: "I know you", with an HMAC over both nonces.
    case auth(device: String, name: String, nonce: Data, proof: Data)
    /// Mac → phone: the Mac's own proof; files may flow.
    case welcome(proof: Data)
    /// Mac → phone: no key for this device (forgotten on the Mac) — pair again.
    case unknown
    /// Phone → Mac: start pairing, committing to the phone's public key.
    case pair(device: String, name: String, commit: Data)
    case pairKey(pub: Data)
    case pairReveal(pub: Data)
    /// Phone → Mac: the user saw the same code.
    case confirm
    /// Mac → phone: pairing finished, the key is stored.
    case paired
    /// Either way: declined, wrong proof or cancelled.
    case denied

    /// Handshake messages are tiny; anything bigger is not one of ours.
    public static let maxSize = 4096

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> PortalMessage? {
        guard data.count <= maxSize else { return nil }
        return try? JSONDecoder().decode(PortalMessage.self, from: data)
    }
}

public enum PortalPairing {
    public enum Role: String, Sendable { case phone = "P", mac = "M" }

    public static func nonce() -> Data { randomBytes(32) }

    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "no system randomness")
        return data
    }

    public static func commitment(to pub: Data) -> Data { Data(SHA256.hash(data: pub)) }

    /// Shared key and the 6-digit code both screens show. Same inputs on both sides give the same output.
    public static func derive(own: Curve25519.KeyAgreement.PrivateKey, peerPub: Data,
                              phonePub: Data, macPub: Data) throws -> (key: Data, code: String) {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
        let secret = try own.sharedSecretFromKeyAgreement(with: peer)
        let salt = phonePub + macPub
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("notchisland-portal-key".utf8), outputByteCount: 32)
        let codeBytes = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                       sharedInfo: Data("notchisland-portal-code".utf8), outputByteCount: 4)
        let n = codeBytes.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        let code = String(format: "%06u", n % 1_000_000)
        return (key.withUnsafeBytes { Data($0) }, code)
    }

    /// "482913" → "482 913".
    public static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    public static func proof(key: Data, role: Role, mac: String, macNonce: Data, phoneNonce: Data) -> Data {
        var message = Data(role.rawValue.utf8)
        message += Data(mac.utf8) + Data([0]) + macNonce + phoneNonce
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Constant-time check of a proof.
    public static func verify(_ proof: Data, key: Data, role: Role, mac: String, macNonce: Data, phoneNonce: Data) -> Bool {
        var message = Data(role.rawValue.utf8)
        message += Data(mac.utf8) + Data([0]) + macNonce + phoneNonce
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: key))
    }
}

/// Pairing keys in the Keychain (this device only, readable after the first unlock).
public struct PortalKeyStore: Sendable {
    public let service: String

    public init(service: String) { self.service = service }

    public func key(for account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    public func set(_ key: Data, for account: String) -> Bool {
        remove(account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: key,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func remove(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
