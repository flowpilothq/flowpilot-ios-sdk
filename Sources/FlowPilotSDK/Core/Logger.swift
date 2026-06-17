import Foundation
import os.log

/// Internal logger for the FlowPilot SDK
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    private let osLog = OSLog(subsystem: "io.flowpilot.sdk", category: "FlowPilot")
    #if DEBUG
    private var logLevel: FlowPilotLogLevel = .info
    #else
    private var logLevel: FlowPilotLogLevel = .error
    #endif
    private let queue = DispatchQueue(label: "io.flowpilot.logger")

    private init() {}

    func setLogLevel(_ level: FlowPilotLogLevel) {
        queue.sync {
            self.logLevel = level
        }
    }

    func verbose(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .verbose, message: message(), file: file, function: function, line: line)
    }

    func debug(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .debug, message: message(), file: file, function: function, line: line)
    }

    func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .info, message: message(), file: file, function: function, line: line)
    }

    func warn(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .warn, message: message(), file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .error, message: message(), file: file, function: function, line: line)
    }

    private func log(level: FlowPilotLogLevel, message: String, file: String, function: String, line: Int) {
        let currentLevel = queue.sync { self.logLevel }
        guard level <= currentLevel else { return }

        let fileName = (file as NSString).lastPathComponent
        let prefix = levelPrefix(level)
        let formattedMessage = "[\(prefix)] [\(fileName):\(line)] \(function) - \(message)"

        switch level {
        case .none:
            break
        case .error:
            os_log(.error, log: osLog, "%{public}@", formattedMessage)
        case .warn:
            os_log(.default, log: osLog, "%{public}@", formattedMessage)
        case .info:
            os_log(.info, log: osLog, "%{public}@", formattedMessage)
        case .debug, .verbose:
            os_log(.debug, log: osLog, "%{public}@", formattedMessage)
        }

        #if DEBUG
        print("[FlowPilot] \(formattedMessage)")
        #endif
    }

    private func levelPrefix(_ level: FlowPilotLogLevel) -> String {
        switch level {
        case .none: return ""
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .verbose: return "VERBOSE"
        }
    }
}
