import Foundation
import TgWsProxyCore

@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var text: String = ""
    private var lines: [String] = []
    private let maxLines = 300
    private let fileURL: URL
    var verbose = false

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("proxy.log")
    }

    func i(_ msg: String) { append("I", msg) }
    func d(_ msg: String) {
        guard verbose else { return }
        append("D", msg)
    }
    func w(_ msg: String) { append("W", msg) }
    func e(_ msg: String) { append("E", msg) }

    func clear() {
        lines = []
        text = ""
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func snapshotForExport() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tgwsproxy-\(stamp).log.txt")
        var body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if body.isEmpty {
            body = lines.joined(separator: "\n")
        }
        guard !body.isEmpty else { return nil }
        do {
            try sanitize(body).write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    private func append(_ level: String, _ msg: String) {
        let line = "[\(level)] \(sanitize(msg))"
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        text = lines.joined(separator: "\n")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) {
                handle.write(data)
            }
        } else {
            try? (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func sanitize(_ msg: String) -> String {
        // Mask long hex secrets in logs
        var out = msg
        if let range = out.range(of: #"secret=dd[0-9a-fA-F]{32}"#, options: .regularExpression) {
            out.replaceSubrange(range, with: "secret=dd****")
        }
        return out
    }
}
