import CryptoKit
import Foundation
import Security

enum PairingError: Error { case malformedQR, invalidKey, keychain(OSStatus), notPaired, decryptFailed }

struct PairingMaterial: Codable, Sendable {
    let document: PairingDocument
    let clientPrivateKey: Data
    let clientPublicKey: Data
    let sharedSecret: Data
}

final class PairingStore: @unchecked Sendable {
    static let shared = PairingStore()
    private let account = "pairing-v1"

    func parse(url: URL) throws -> PairingDocument {
        guard url.scheme == "k7bridge", url.host == "pair",
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Data(base64URLEncoded: encoded) else { throw PairingError.malformedQR }
        return try JSONDecoder.k7.decode(PairingDocument.self, from: data)
    }

    func pair(document: PairingDocument) throws -> PairingMaterial {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let gatewayKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: document.gatewayPublicKey) else { throw PairingError.invalidKey }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: gatewayKey)
        let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data(document.oneTimeCode.utf8), sharedInfo: Data("k7bridge-pair-v1".utf8), outputByteCount: 32)
        let material = PairingMaterial(document: document,
            clientPrivateKey: privateKey.rawRepresentation,
            clientPublicKey: privateKey.publicKey.rawRepresentation,
            sharedSecret: symmetric.withUnsafeBytes { Data($0) })
        try save(material)
        return material
    }

    func load() throws -> PairingMaterial {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "K7Bridge",
            kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw PairingError.notPaired }
        guard status == errSecSuccess, let data = item as? Data else { throw PairingError.keychain(status) }
        return try JSONDecoder.k7.decode(PairingMaterial.self, from: data)
    }

    func decryptPush(nonce: Data, ciphertext: Data) throws -> IncomingCallPayload {
        let material = try load()
        let key = SymmetricKey(data: material.sharedSecret)
        guard let sealed = try? ChaChaPoly.SealedBox(combined: nonce + ciphertext),
              let clear = try? ChaChaPoly.open(sealed, using: key) else { throw PairingError.decryptFailed }
        return try JSONDecoder.k7.decode(IncomingCallPayload.self, from: clear)
    }

    private func save(_ material: PairingMaterial) throws {
        let data = try JSONEncoder.k7.encode(material)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "K7Bridge", kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var value = base; value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
    }
}

extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

extension JSONEncoder {
    static var k7: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
    static var k7Sorted: JSONEncoder { let value = JSONEncoder.k7; value.outputFormatting = [.sortedKeys]; return value }
}
extension JSONDecoder {
    static var k7: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
