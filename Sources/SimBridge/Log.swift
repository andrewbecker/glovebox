import Foundation

/// Diagnostics on stderr (stdout carries MCP). Enabled with GLOVEBOX_DEBUG=1.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["GLOVEBOX_DEBUG"] == "1"
    private static let start = ContinuousClock.now

    /// Always written: something an operator should know, such as a slower
    /// fallback serving every call.
    static func notice(_ message: String) {
        let ms = (ContinuousClock.now - start).inMilliseconds
        try? FileHandle.standardError.write(contentsOf: Data("[glovebox +\(ms)ms] \(message)\n".utf8))
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let ms = (ContinuousClock.now - start).inMilliseconds
        // Throws instead of raising if stderr is closed (SIGPIPE is ignored).
        try? FileHandle.standardError.write(contentsOf: Data("[glovebox +\(ms)ms] \(message())\n".utf8))
    }
}
