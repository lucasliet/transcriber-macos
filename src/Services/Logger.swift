import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

class Logger {
    static let shared = Logger()

    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.transcriber.logger", qos: .utility)
    private let maxLines = 50

    private init() {
        logFileURL = URL(fileURLWithPath: "/tmp/transcriber.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    private func log(_ level: LogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line)] \(message)\n"

        queue.async { [weak self] in
            guard let self = self, let data = logMessage.data(using: .utf8) else { return }
            self.appendAndTrim(data)
        }
    }

    private func appendAndTrim(_ data: Data) {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            try? data.write(to: logFileURL)
            return
        }

        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines.append(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? "")

        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        let trimmed = lines.joined(separator: "\n") + "\n"
        try? trimmed.data(using: .utf8)?.write(to: logFileURL)
    }

    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(.debug, message, file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(.info, message, file: file, function: function, line: line)
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(.warning, message, file: file, function: function, line: line)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        shared.log(.error, message, file: file, function: function, line: line)
    }

    static func logFilePath() -> String {
        return shared.logFileURL.path
    }
}