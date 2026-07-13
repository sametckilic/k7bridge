import CryptoKit
import Foundation
import Security

enum PairingError: LocalizedError {
    case malformedQR, invalidKey, invalidCertificate, keychain(OSStatus), notPaired, decryptFailed

    var errorDescription: String? {
        switch self {
        case .malformedQR: return "Eşleştirme kodu geçerli değil."
        case .invalidKey: return "Gateway güvenlik anahtarı geçerli değil."
        case .invalidCertificate: return "Gateway sertifika parmak izi geçerli değil."
        case .keychain(let status): return "Eşleştirme telefona kaydedilemedi (\(status))."
        case .notPaired: return "Henüz bir gateway eşleştirilmedi."
        case .decryptFailed: return "Şifreli bildirim çözülemedi."
        }
    }
}

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
        guard let document = try? JSONDecoder.k7.decode(PairingDocument.self, from: data),
              !document.gatewayId.isEmpty, !document.host.isEmpty, document.port > 0,
              document.oneTimeCode.count == 6,
              document.oneTimeCode.allSatisfy(\.isNumber),
              document.gatewayPublicKey.count == 32 else { throw PairingError.malformedQR }
        let fingerprint = document.certificateSHA256.lowercased()
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit }) else { throw PairingError.invalidCertificate }
        return document
    }

    func pair(document: PairingDocument) throws -> PairingMaterial {
        if let existing = try? load(),
           existing.document.gatewayId == document.gatewayId,
           existing.document.gatewayPublicKey == document.gatewayPublicKey,
           existing.document.oneTimeCode == document.oneTimeCode {
            return PairingMaterial(document: document,
                clientPrivateKey: existing.clientPrivateKey,
                clientPublicKey: existing.clientPublicKey,
                sharedSecret: existing.sharedSecret)
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let gatewayKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: document.gatewayPublicKey) else { throw PairingError.invalidKey }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: gatewayKey)
        let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data(document.oneTimeCode.utf8), sharedInfo: Data("k7bridge-pair-v1".utf8), outputByteCount: 32)
        let material = PairingMaterial(document: document,
            clientPrivateKey: privateKey.rawRepresentation,
            clientPublicKey: privateKey.publicKey.rawRepresentation,
            sharedSecret: symmetric.withUnsafeBytes { Data($0) })
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

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "K7Bridge",
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.keychain(status) }
    }

    func store(_ material: PairingMaterial) throws {
        try save(material)
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
    static var k7: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Geçersiz ISO-8601 tarihi: \(string)")
        }
        return value
    }
}
