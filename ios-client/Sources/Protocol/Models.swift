import Foundation

enum CallState: String, Codable, Sendable { case idle, incoming, dialing, connecting, active, ended, failed }
enum SMSState: String, Codable, Sendable { case queued, sent, failed }

struct GatewayCall: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var handle: String
    var displayName: String?
    var state: CallState
}

struct SMSMessage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let handle: String
    let text: String
    let date: Date
    let isFromMe: Bool
    var state: SMSState
}

struct DeviceStatus: Codable, Equatable, Sendable {
    var carrier = "—"
    var radioTechnology = "—"
    var signalBars = 0
    var simReady = false
    var batteryLevel = 0.0
    var charging = false
    var thermalState = "nominal"
    var hotspotEnabled = false
    var clientConnected = false
    var audioGatePassed = false

    enum CodingKeys: String, CodingKey { case carrier, radioTechnology, signalBars, simReady, batteryLevel, charging, thermalState, hotspotEnabled, clientConnected, audioGatePassed }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        carrier = try values.decodeIfPresent(String.self, forKey: .carrier) ?? "—"
        radioTechnology = try values.decodeIfPresent(String.self, forKey: .radioTechnology) ?? "—"
        signalBars = try values.decodeIfPresent(Int.self, forKey: .signalBars) ?? 0
        simReady = try values.decodeIfPresent(Bool.self, forKey: .simReady) ?? false
        batteryLevel = try values.decodeIfPresent(Double.self, forKey: .batteryLevel) ?? 0
        charging = try values.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        thermalState = try values.decodeIfPresent(String.self, forKey: .thermalState) ?? "nominal"
        hotspotEnabled = try values.decodeIfPresent(Bool.self, forKey: .hotspotEnabled) ?? false
        clientConnected = try values.decodeIfPresent(Bool.self, forKey: .clientConnected) ?? false
        audioGatePassed = try values.decodeIfPresent(Bool.self, forKey: .audioGatePassed) ?? false
    }
}

struct ControlEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    let v: Int
    let type: String
    let messageId: UUID
    let sequence: UInt64
    let sentAt: Date
    let payload: Payload
    let auth: String?

    init(type: String, messageId: UUID = UUID(), sequence: UInt64, payload: Payload, auth: String? = nil) {
        self.v = 1; self.type = type; self.messageId = messageId
        self.sequence = sequence; self.sentAt = Date(); self.payload = payload; self.auth = auth
    }
}

struct EmptyPayload: Codable, Sendable {}
struct CallCommand: Codable, Sendable { let callId: UUID }
struct DialCommand: Codable, Sendable { let callId: UUID; let handle: String }
struct DTMFCommand: Codable, Sendable { let callId: UUID; let digit: String }
struct SMSListCommand: Codable, Sendable { let cursor: String?; let limit: Int }
struct SMSSendCommand: Codable, Sendable { let smsId: String; let handle: String; let text: String }
struct HeartbeatPayload: Codable, Sendable { let activeCallId: UUID? }
struct PairCommand: Codable, Sendable { let clientId: UUID; let clientPublicKey: Data; let oneTimeCode: String }

struct IncomingHeader: Decodable { let v: Int; let type: String; let messageId: UUID; let sequence: UInt64 }
struct IncomingCallPayload: Codable, Sendable { let callId: UUID; let handle: String; let displayName: String? }
struct CallUpdatePayload: Codable, Sendable { let callId: UUID; let state: CallState; let reason: String? }
struct SMSPagePayload: Codable, Sendable { let items: [SMSMessage]; let nextCursor: String? }
struct SMSUpdatePayload: Codable, Sendable { let smsId: String; let state: SMSState; let error: String? }
struct SnapshotPayload: Codable, Sendable { let call: GatewayCall?; let device: DeviceStatus; let smsCursor: String? }

struct PairingDocument: Codable, Sendable {
    let gatewayId: String
    let host: String
    let port: UInt16
    let oneTimeCode: String
    let gatewayPublicKey: Data
    let certificateSHA256: String
    let relayURL: URL
    let relaySecret: String
}

enum PhoneNumberPolicy {
    static let emergency = ["112", "911", "999", "110", "155", "156"]
    static func normalize(_ raw: String, countryCode: String = "+90") -> String? {
        let trimmed = String(raw.filter { $0.isNumber || $0 == "+" })
        guard !trimmed.isEmpty, !emergency.contains(String(trimmed.filter(\.isNumber))) else { return nil }
        let value: String
        if trimmed.hasPrefix("+") { value = trimmed }
        else if trimmed.hasPrefix("00") { value = "+" + String(trimmed.dropFirst(2)) }
        else if trimmed.hasPrefix("0") { value = countryCode + String(trimmed.dropFirst()) }
        else { value = countryCode + trimmed }
        let digits = value.dropFirst()
        guard value.first == "+", digits.count >= 7, digits.count <= 15, digits.allSatisfy(\.isNumber) else { return nil }
        return value
    }
}
