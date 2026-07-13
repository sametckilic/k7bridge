import Combine
import Foundation

@MainActor
final class ClientDiagnostics: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []

    private let directory: URL
    private let fileURL: URL
    private var sequence: UInt64 = 0
    private let maximumBytes = 1_048_576

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appending(path: "K7Bridge", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "client-events.jsonl")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        entries = Self.readEntries(from: [fileURL.appendingPathExtension("1"), fileURL], limit: 200)
        sequence = entries.map(\.sequence).max() ?? 0
    }

    func record(component: String, event: String, level: String = "info", fields: [String: String] = [:]) {
        sequence += 1
        let entry = DiagnosticEntry(timestamp: Date(), sequence: sequence, source: "client",
                                    level: level, component: component, event: event, fields: fields)
        rotateIfNeeded()
        if let data = try? JSONEncoder.k7Sorted.encode(entry) {
            var line = data
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            }
        }
        entries.append(entry)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func exportText(gatewayEntries: [DiagnosticEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (entries + gatewayEntries)
            .sorted { $0.timestamp < $1.timestamp }
            .map { entry in
                let details = entry.fields.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                return "\(formatter.string(from: entry.timestamp)) [\(entry.source)/\(entry.component)] \(entry.level.uppercased()) \(entry.event)\(details.isEmpty ? "" : " \(details)")"
            }
            .joined(separator: "\n")
    }

    private func rotateIfNeeded() {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= maximumBytes else { return }
        let previous = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }

    private static func readEntries(from urls: [URL], limit: Int) -> [DiagnosticEntry] {
        var result: [DiagnosticEntry] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let data = Data(line.utf8)
                guard let entry = try? JSONDecoder.k7.decode(DiagnosticEntry.self, from: data) else { continue }
                result.append(entry)
            }
        }
        return Array(result.suffix(limit))
    }
}
