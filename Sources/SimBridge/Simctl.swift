import Foundation

/// Thin async wrapper around `xcrun simctl`, used for operations where the
/// private frameworks offer no speed advantage.
public enum Simctl {
    public struct Failure: Error, CustomStringConvertible {
        public let arguments: [String]
        public let status: Int32
        public let stderr: String
        public var description: String {
            "simctl \(arguments.joined(separator: " ")) failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    public struct Timeout: Error, CustomStringConvertible {
        public let arguments: [String]
        public let limit: Duration
        public var description: String {
            "simctl \(arguments.joined(separator: " ")) did not finish within \(limit.inMilliseconds / 1000) s and was stopped."
        }
    }

    /// - Parameters:
    ///   - childEnvironment: variables passed to processes simctl spawns
    ///     (simctl forwards `SIMCTL_CHILD_`-prefixed variables).
    ///   - input: data written to simctl's standard input (e.g. for `pbcopy`).
    ///   - timeout: how long simctl may run before it is terminated. Cancelling
    ///     the calling task terminates it too.
    @discardableResult
    public static func run(_ arguments: [String], childEnvironment: [String: String] = [:], input: Data? = nil,
                           timeout: Duration = .seconds(60)) async throws -> Data {
        let invocation = Invocation(arguments: arguments, childEnvironment: childEnvironment)
        let result = try await withTaskCancellationHandler {
            try await invocation.run(input: input, timeout: timeout)
        } onCancel: {
            invocation.stop(.cancelled)
        }
        switch invocation.stopReason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw Timeout(arguments: arguments, limit: timeout)
        case nil: break
        }
        guard result.status == 0 else {
            throw Failure(arguments: arguments, status: result.status, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return result.stdout
    }
}

/// One simctl process. `stop` can come from any thread at any time: before
/// launch, while running, or after exit.
private final class Invocation: @unchecked Sendable {
    enum Stop { case cancelled, timedOut }

    private let process = Process()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var launched = false
    private var exited = false
    private var stopped: Stop?

    init(arguments: [String], childEnvironment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        if !childEnvironment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in childEnvironment {
                environment["SIMCTL_CHILD_" + key] = value
            }
            process.environment = environment
        }
    }

    /// Why the process was stopped early, if it was.
    var stopReason: Stop? { lock.withLock { stopped } }

    /// Runs simctl until it exits and returns its status and output.
    func run(input: Data?, timeout: Duration) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let stdout = Pipe(), stderr = Pipe(), stdin = input.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin ?? FileHandle.nullDevice
        let output = Output()
        let drained = DispatchGroup()
        return try await withCheckedThrowingContinuation { continuation in
            // Entered before launch so a fast exit cannot notify before the
            // pipes are drained.
            drained.enter()
            drained.enter()
            process.terminationHandler = { [self] process in
                lock.withLock { exited = true }
                drained.notify(queue: .global()) {
                    continuation.resume(returning: (process.terminationStatus, output.stdout, output.stderr))
                }
            }
            do {
                try lock.withLock {
                    if stopped != nil { throw CancellationError() }
                    try process.run()
                    launched = true
                }
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Drain pipes concurrently so large outputs (e.g. `list -j`) can't deadlock.
            DispatchQueue.global().async {
                output.stdout = stdout.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
            DispatchQueue.global().async {
                output.stderr = stderr.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
            if let stdin, let input {
                DispatchQueue.global().async {
                    // Throws instead of raising if simctl exits without reading
                    // it all (SIGPIPE is ignored).
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
                stop(.timedOut)
            }
        }
    }

    func stop(_ reason: Stop) {
        lock.withLock {
            guard stopped == nil, !exited else { return }
            if launched {
                // Already exited; its termination handler is on the way.
                guard process.isRunning else { return }
                process.terminate()
            }
            stopped = reason
        }
    }
}

/// Filled by the pipe readers; read only after both have finished.
private final class Output: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}
