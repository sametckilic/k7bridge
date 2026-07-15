import AVFAudio
import CryptoKit
import Foundation
import Network

/// Encrypted 16 kHz mono media path used after CallKit activates the audio
/// session. Packets are intentionally small (20 ms) so local hotspot latency
/// remains low; Opus can be added later without changing call control.
final class MediaEngine: @unchecked Sendable {
    var onDiagnostic: ((String, String, [String: String]) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.example.K7Bridge.media", qos: .userInteractive)
    private var connection: NWConnection?
    private var generation = UUID()
    private var key: SymmetricKey?
    private var callId: UUID?
    private var sendSequence: UInt64 = 0
    private var receivedSequence: UInt64 = 0
    private var pendingMic = Data()
    private var resamplePosition = 0.0
    private var muted = false
    private var inputTapInstalled = false
    private var sentPackets: UInt64 = 0
    private var receivedPackets: UInt64 = 0

    init() {
        engine.attach(player)
    }

    func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            self?.diagnostic(granted ? "microphone_permission_granted" : "microphone_permission_denied",
                             level: granted ? "info" : "error")
        }
    }

    func isConfigured(for callId: UUID) -> Bool {
        self.callId == callId && connection != nil && engine.isRunning
    }

    func configure(host: String, port: UInt16, keyData: Data, callId: UUID) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetooth])
        // CallKit owns route selection. Forcing speakerphone here made its route
        // button lie and fed the remote voice straight back into our microphone.
        try session.overrideOutputAudioPort(.none)

        let mediaKey = Self.deriveKey(sharedSecret: keyData, callId: callId)
        let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = engine.inputNode
        do {
            // Voice-chat mode does not by itself guarantee VoiceProcessingIO for
            // AVAudioEngine. Explicit processing provides acoustic echo cancellation.
            try input.setVoiceProcessingEnabled(true)
            diagnostic("voice_processing_enabled")
        } catch {
            diagnostic("voice_processing_unavailable", level: "error",
                       fields: ["error": error.localizedDescription])
            throw MediaError.voiceProcessingUnavailable(error.localizedDescription)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MediaError.inputUnavailable
        }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let currentGeneration = UUID()
        generation = currentGeneration
        self.key = mediaKey
        self.callId = callId
        sendSequence = 0
        receivedSequence = 0
        pendingMic.removeAll(keepingCapacity: true)
        resamplePosition = 0
        sentPackets = 0
        receivedPackets = 0

        input.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            // AVAudioEngine owns the tap buffer and may reuse it immediately after
            // this callback, so copy the mono samples before leaving the callback.
            let samples = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
            self.queue.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.consumeMicrophone(samples, sampleRate: inputFormat.sampleRate)
            }
        }
        inputTapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()

        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let socket = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        connection = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, self.connection === socket, self.generation == currentGeneration else { return }
            switch state {
            case .ready:
                self.diagnostic("transport_ready", fields: ["host": host, "port": String(port)])
            case .failed(let error):
                self.diagnostic("transport_failed", level: "error",
                                fields: ["error": error.localizedDescription])
            case .waiting(let error):
                self.diagnostic("transport_waiting", level: "warning",
                                fields: ["error": error.localizedDescription])
            default: break
            }
        }
        socket.start(queue: queue)
        receiveLoop(connection: socket, generation: currentGeneration)
        diagnostic("session_started", fields: ["callId": callId.uuidString,
                                                "inputRate": String(Int(inputFormat.sampleRate))])
    }

    func setMuted(_ value: Bool) {
        queue.async { [weak self] in self?.muted = value }
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        diagnostic("route_override_changed", fields: ["speaker": String(enabled)])
    }

    func stop() {
        generation = UUID()
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        player.stop()
        if engine.isRunning { engine.stop() }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        key = nil
        callId = nil
        pendingMic.removeAll(keepingCapacity: false)
        sendSequence = 0
        receivedSequence = 0
    }

    private func consumeMicrophone(_ data: Data, sampleRate: Double) {
        let frameCount = data.count / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }
        let step = sampleRate / 16_000.0
        var samples = [Int16]()
        samples.reserveCapacity(Int(Double(frameCount) / step) + 2)
        var position = resamplePosition
        data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Float.self)
            while position < Double(frameCount) {
                let index = min(Int(position), frameCount - 1)
                let value = muted ? Float.zero : max(-1, min(1, input[index]))
                samples.append(Int16((value * 32_767).rounded()))
                position += step
            }
        }
        resamplePosition = position - Double(frameCount)
        samples.withUnsafeBytes { pendingMic.append(contentsOf: $0) }

        let packetBytes = 320 * MemoryLayout<Int16>.size
        while pendingMic.count >= packetBytes {
            let pcm = pendingMic.prefix(packetBytes)
            pendingMic.removeFirst(packetBytes)
            send(pcm: Data(pcm), frames: 320)
        }
    }

    private func send(pcm: Data, frames: UInt16) {
        guard let connection, let key, let callId else { return }
        sendSequence &+= 1
        let header = Self.header(direction: 1, frames: frames, sequence: sendSequence, callId: callId)
        let nonceData = Self.nonce(direction: 1, sequence: sendSequence)
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let sealed = try ChaChaPoly.seal(pcm, using: key, nonce: nonce, authenticating: header)
            var packet = header
            packet.append(sealed.ciphertext)
            packet.append(sealed.tag)
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.diagnostic("packet_send_failed", level: "error",
                                    fields: ["error": error.localizedDescription])
                }
            })
            sentPackets &+= 1
            if sentPackets == 1 || sentPackets.isMultiple(of: 250) {
                diagnostic("uplink_flow", fields: ["packets": String(sentPackets)])
            }
        } catch {
            diagnostic("packet_encrypt_failed", level: "error",
                       fields: ["error": error.localizedDescription])
        }
    }

    private func receiveLoop(connection: NWConnection, generation: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection,
                  self.generation == generation else { return }
            if let data { self.consumeDownlink(data) }
            if let error {
                self.diagnostic("packet_receive_failed", level: "error",
                                fields: ["error": error.localizedDescription])
                return
            }
            self.receiveLoop(connection: connection, generation: generation)
        }
    }

    private func consumeDownlink(_ packet: Data) {
        guard packet.count >= 48, let key, let callId,
              packet.prefix(4) == Data("K7M1".utf8), packet[4] == 1, packet[5] == 2 else { return }
        let frames = Self.readUInt16(packet, at: 6)
        let sequence = Self.readUInt64(packet, at: 8)
        guard frames > 0, frames <= 320, sequence > receivedSequence,
              Self.readUUID(packet, at: 16) == callId,
              packet.count == 32 + Int(frames) * 2 + 16 else { return }
        let encrypted = packet.subdata(in: 32..<packet.count)
        let ciphertext = encrypted.dropLast(16)
        let tag = encrypted.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Self.nonce(direction: 2, sequence: sequence)),
                                               ciphertext: ciphertext, tag: tag)
            let pcm = try ChaChaPoly.open(box, using: key, authenticating: packet.prefix(32))
            receivedSequence = sequence
            schedule(pcm: pcm, frames: AVAudioFrameCount(frames))
            receivedPackets &+= 1
            if receivedPackets == 1 || receivedPackets.isMultiple(of: 250) {
                diagnostic("downlink_flow", fields: ["packets": String(receivedPackets)])
            }
        } catch {
            diagnostic("packet_decrypt_failed", level: "error",
                       fields: ["error": error.localizedDescription])
        }
    }

    private func schedule(pcm: Data, frames: AVAudioFrameCount) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            for index in 0..<Int(frames) { channel[index] = Float(input[index]) / 32_768.0 }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private static func deriveKey(sharedSecret: Data, callId: UUID) -> SymmetricKey {
        let info = Data("k7bridge-media-v1|\(callId.uuidString)".utf8)
        let code = HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: sharedSecret))
        return SymmetricKey(data: Data(code))
    }

    private static func header(direction: UInt8, frames: UInt16, sequence: UInt64, callId: UUID) -> Data {
        var data = Data("K7M1".utf8)
        data.append(1); data.append(direction)
        var frameValue = frames.bigEndian
        withUnsafeBytes(of: &frameValue) { data.append(contentsOf: $0) }
        var sequenceValue = sequence.bigEndian
        withUnsafeBytes(of: &sequenceValue) { data.append(contentsOf: $0) }
        var uuid = callId.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        return data
    }

    private static func nonce(direction: UInt8, sequence: UInt64) -> Data {
        var data = Data([direction, 0, 0, 0])
        var value = sequence.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    private static func readUUID(_ data: Data, at offset: Int) -> UUID {
        let bytes = data.subdata(in: offset..<(offset + 16))
        return bytes.withUnsafeBytes { raw in
            NSUUID(uuidBytes: raw.bindMemory(to: UInt8.self).baseAddress!) as UUID
        }
    }

    private func diagnostic(_ event: String, level: String = "info", fields: [String: String] = [:]) {
        onDiagnostic?(event, level, fields)
    }
}

enum MediaError: LocalizedError {
    case inputUnavailable
    case voiceProcessingUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "Mikrofon ses biçimi kullanılamıyor."
        case .voiceProcessingUnavailable(let detail):
            return "Yankı engelleme başlatılamadı: \(detail)"
        }
    }
}
