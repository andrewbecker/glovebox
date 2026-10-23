import Foundation
import SimBridgeObjC

/// A JSON object from the debug adapter. DAP bodies are loosely typed, so
/// they stay dictionaries; this wrapper carries one across tasks.
struct DAPObject: @unchecked Sendable {
    let value: [String: Any]

    subscript(key: String) -> Any? { value[key] }
    func string(_ key: String) -> String? { value[key] as? String }
    func int(_ key: String) -> Int? { (value[key] as? NSNumber)?.intValue }
    func object(_ key: String) -> DAPObject? { (value[key] as? [String: Any]).map(DAPObject.init) }
    func objects(_ key: String) -> [DAPObject] { ((value[key] as? [[String: Any]]) ?? []).map(DAPObject.init) }
}

/// A Debug Adapter Protocol client driving Xcode's lldb-dap over its stdin
/// and stdout. lldb-dap is a stable, documented front end to lldb, so glovebox
/// needs no private debugger API; simulator apps are host processes, so it
/// attaches to them by pid like any Mac process.
final class DAPClient: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case running
        /// Stopped at a breakpoint, an exception or a pause.
        case stopped(reason: String, threadID: Int, description: String?)
        /// The process exited or the adapter went away.
        case ended(String)
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var nextSequence = 1
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<DAPObject, Error>] = [:]
    private var currentState = State.running
    private var initialized = false

    var state: State { lock.withLock { currentState } }
    var isInitialized: Bool { lock.withLock { initialized } }

    /// Where Xcode keeps lldb-dap.
    static func adapterPath() throws -> String {
        guard let developer = SBDeveloperDirectory() else {
            throw SimBridgeError("No Xcode is selected (xcode-select -p failed), so there is no lldb-dap to debug with.")
        }
        let path = developer + "/usr/bin/lldb-dap"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw SimBridgeError("\(path) is missing; lldb-dap ships with Xcode 16 and later.")
        }
        return path
    }

    init() throws {
        process.executableURL = URL(fileURLWithPath: try Self.adapterPath())
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.end("lldb-dap exited")
            } else {
                self.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in self?.end("lldb-dap exited") }
        try process.run()
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Sends a request and returns its response body, throwing the adapter's
    /// message if it refused.
    @discardableResult
    func request(_ command: String, _ arguments: [String: Any] = [:], timeout: Duration = .seconds(30)) async throws -> DAPObject {
        let response = try await withThrowingTaskGroup(of: DAPObject.self) { group in
            let sequence = lock.withLock {
                defer { nextSequence += 1 }
                return nextSequence
            }
            let message = DAPObject(value: ["seq": sequence, "type": "request", "command": command, "arguments": arguments])
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let ended: String? = self.lock.withLock {
                        if case .ended(let why) = self.currentState { return why }
                        self.pending[sequence] = continuation
                        return nil
                    }
                    if let ended {
                        continuation.resume(throwing: SimBridgeError("The debugger is gone (\(ended)). Call debug_attach again."))
                        return
                    }
                    self.send(message.value)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                let continuation = self.lock.withLock { self.pending.removeValue(forKey: sequence) }
                continuation?.resume(throwing: SimBridgeError("lldb-dap did not answer \(command) within \(timeout.inMilliseconds / 1000) s."))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard (response["success"] as? Bool) == true else {
            let detail = response.object("body")?.object("error")?.string("format")
            throw SimBridgeError("lldb-dap refused \(command): \(detail ?? response.string("message") ?? "no reason given").")
        }
        return response.object("body") ?? DAPObject(value: [:])
    }

    /// Waits until the process stops or ends, up to `timeout`.
    func waitUntilStopped(timeout: Duration) async throws -> State {
        let deadline = ContinuousClock.now + timeout
        while true {
            let state = self.state
            if state != .running || ContinuousClock.now >= deadline { return state }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits for the adapter's initialized event, which comes after attach.
    func waitUntilInitialized(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !isInitialized {
            if case .ended(let why) = state { throw SimBridgeError("The debugger is gone (\(why)).") }
            guard ContinuousClock.now < deadline else { throw SimBridgeError("lldb-dap did not finish attaching.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func markRunning() {
        lock.withLock { if case .stopped = currentState { currentState = .running } }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func send(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        try? input.fileHandleForWriting.write(contentsOf: frame)
    }

    private func receive(_ data: Data) {
        var messages: [DAPObject] = []
        lock.withLock {
            buffer.append(data)
            while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
                else {
                    buffer.removeAll()
                    return
                }
                guard buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex) >= length else { return }
                let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: length)
                if let object = try? JSONSerialization.jsonObject(with: buffer[headerEnd.upperBound..<bodyEnd]) as? [String: Any] {
                    messages.append(DAPObject(value: object))
                }
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            }
        }
        messages.forEach(handle)
    }

    private func handle(_ message: DAPObject) {
        switch message.string("type") {
        case "response":
            guard let sequence = message.int("request_seq") else { return }
            let continuation = lock.withLock { pending.removeValue(forKey: sequence) }
            continuation?.resume(returning: message)
        case "event":
            let body = message.object("body")
            lock.withLock {
                switch message.string("event") {
                case "initialized":
                    initialized = true
                case "stopped":
                    currentState = .stopped(reason: body?.string("reason") ?? "pause",
                                            threadID: body?.int("threadId") ?? 0,
                                            description: body?.string("description") ?? body?.string("text"))
                case "continued":
                    if case .stopped = currentState { currentState = .running }
                case "exited":
                    currentState = .ended("the app exited with code \(body?.int("exitCode") ?? 0)")
                case "terminated":
                    if case .ended = currentState {} else { currentState = .ended("the debug session ended") }
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private func end(_ why: String) {
        let waiting = lock.withLock {
            if case .ended = currentState {} else { currentState = .ended(why) }
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        waiting.forEach { $0.resume(throwing: SimBridgeError("The debugger is gone (\(why)). Call debug_attach again.")) }
    }
}
