import Foundation

/// App-side boot trace (Documents/Logs/ideck.log) and log tail helpers.
enum DiagLog {
    private static let queue = DispatchQueue(label: "ideck.diaglog")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = Paths.appLog
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Starts a new trace for this app launch (keeps the previous one).
    static func rotate() {
        let fm = FileManager.default
        let prev = Paths.previousAppLog
        try? fm.removeItem(at: prev)
        try? fm.moveItem(at: Paths.appLog, to: prev)
    }

    /// Last `lines` printable lines of a log file (reads at most `maxBytes`).
    static func tail(_ url: URL, lines: Int, maxBytes: UInt64 = 32768) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > maxBytes ? size - maxBytes : 0)
        let data = h.readDataToEndOfFile()
        let text = clean(String(decoding: data, as: UTF8.self))
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines))
    }

    /// Strips terminal escape sequences and control characters from serial
    /// console output.
    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?!]*[A-Za-z]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\r", with: "\n")
        out.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }
        return out
    }
}
