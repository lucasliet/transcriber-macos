import Foundation

/// A plain-text log next to the unified log, so `tail -f` works again.
///
/// `os.Logger` is the better mechanism — structured, privacy-aware, no I/O on the caller's
/// thread — but reading it means `/usr/bin/log show --predicate …`, which nobody remembers
/// under pressure. This mirrors the events that matter into a file you can just open, and
/// caps it so it can never grow without bound.
enum FileLog {
    static let url = URL(fileURLWithPath: "/tmp/murmur-youtube.log")

    /// Matches the old app: enough to see the last dictation, small enough to never matter.
    private static let maxLines = 50

    private static let queue = DispatchQueue(label: "ai.pivotstudio.murmur-youtube.filelog", qos: .utility)

    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func debug(_ message: String) { write("DEBUG", message) }
    static func info(_ message: String) { write("INFO", message) }
    static func warning(_ message: String) { write("WARNING", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// Writes on a utility queue: a dictation path should never block on disk.
    ///
    /// The timestamp is formatted *inside* the queue too. `DateFormatter` is not
    /// thread-safe, and callers here span the main actor, the hotkey tap and the engine
    /// actors — formatting at the call site would be a real race.
    private static func write(_ level: String, _ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(level)] \(message)"
            var lines = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init) ?? []

            // A trailing newline leaves an empty final element; drop it so the cap counts
            // real lines and the file doesn't accumulate blanks.
            if lines.last?.isEmpty == true { lines.removeLast() }

            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }

            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
