import AVFAudio
import CryptoKit
import Foundation
import Network

/// Owns the client audio session only after CallKit activates it. Audio is never
/// started from a push callback. Gateway audio remains fail-closed until its probe passes.
final class MediaEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var connection: NWConnection?
    private var sequence: UInt16 = 0
    private var muted = false
    private let queue = DispatchQueue(label: "com.example.K7Bridge.media", qos: .userInteractive)

    func configure(host: String, port: UInt16, keyData: Data, callId: UUID) throws {
        stop()
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        self.connection = connection
        connection.start(queue: queue)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
            guard let self, !self.muted else { return }
            // PCM transport is intentionally disabled here. The production encoder is
            // enabled only together with the device-verified gateway Opus/AudioBridge gate.
            _ = buffer
        }
        try engine.start()
        receiveLoop(key: SymmetricKey(data: keyData), callId: callId)
    }

    func setMuted(_ value: Bool) { muted = value }

    func stop() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        connection?.cancel(); connection = nil; sequence = 0
    }

    private func receiveLoop(key: SymmetricKey, callId: UUID) {
        connection?.receiveMessage { [weak self] _, _, _, _ in
            guard let self, self.connection != nil else { return }
            self.receiveLoop(key: key, callId: callId)
        }
    }
}

