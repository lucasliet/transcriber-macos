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
    private let fileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.transcriber.logger", qos: .utility)

    private init() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let transcriberDir = appSupportURL.appendingPathComponent("Transcriber")
        let logsDir = transcriberDir.appendingPathComponent("Logs")

        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayString = dateFormatter.string(from: Date())

        logFileURL = logsDir.appendingPathComponent("transcriber-\(todayString).log")

        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        cleanOldLogs(in: logsDir, olderThanDays: 7)
    }

    deinit {
        try? fileHandle?.close()
    }

    private func cleanOldLogs(in directory: URL, olderThanDays days: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        for file in files where file.pathExtension == "log" {
            if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
               let creationDate = attributes[.creationDate] as? Date,
               creationDate < cutoffDate {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func log(_ level: LogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line)] \(message)\n"

        queue.async { [weak self] in
            guard let self = self, let data = logMessage.data(using: .utf8) else { return }
            self.fileHandle?.write(data)
        }

        #if DEBUG
        print(logMessage, terminator: "")
        #endif
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
