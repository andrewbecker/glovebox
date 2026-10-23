import Darwin
import Foundation

extension DeviceSession {
    /// Throws when the app on this device is paused in the debugger.
    public nonisolated func refuseIfPaused() async throws {
        if let note = await Debugger.shared.pausedNote(udid: udid) { throw SimBridgeError(note) }
    }
}

/// One debug session per simulator, over lldb-dap. While the app is paused
/// its screen is frozen and it cannot take input, so glovebox refuses input and
/// tree reads instead of letting them time out.
public actor Debugger {
    public static let shared = Debugger()

    /// A session nobody has used this long is detached, so a forgotten one
    /// does not leave an app paused or slowed by a debugger.
    static let idleLimit: Duration = .seconds(600)

    struct Session {
        let client: DAPClient
        let pid: Int
        let bundleID: String
        var lineBreakpoints: [String: [[String: Any]]] = [:]
        var functionBreakpoints: [[String: Any]] = []
        var lastUse = ContinuousClock.now
    }

    private var sessions: [String: Session] = [:]

    public struct Stop: Sendable {
        public let reason: String
        public let description: String?
        public let frames: [String]
    }

    /// Attaches to `bundleID` on `udid`: relaunched under the debugger (so
    /// breakpoints are in place from its first line), or as it runs.
    /// `breakpoints` are "File.swift:42" or function names, set before it runs.
    public func attach(udid: String, bundleID: String, pid: Int?, relaunch: Bool, breakpoints: [String]) async throws -> String {
        if sessions[udid] != nil { await detach(udid: udid) }
        try await Self.checkDebuggable(udid: udid, bundleID: bundleID)
        if let running = try await Self.runningPID(udid: udid, bundleID: bundleID) {
            try Self.checkNotTraced(running, bundleID: bundleID)
        }
        let target: Int
        if relaunch {
            let output = try await Simctl.run(["launch", "--terminate-running-process", "--wait-for-debugger", udid, bundleID])
            guard let launched = Int(String(decoding: output, as: UTF8.self).split(separator: ":").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
                throw SimBridgeError("simctl launch printed no pid for \(bundleID).")
            }
            target = launched
        } else if let pid {
            target = pid
        } else if let running = try await Self.runningPID(udid: udid, bundleID: bundleID) {
            target = running
        } else {
            throw SimBridgeError("\(bundleID) is not running. Launch it first, or pass relaunch: true.")
        }

        let client = try DAPClient()
        do {
            try await client.request("initialize", ["adapterID": "lldb-dap", "clientID": "glovebox", "clientName": "glovebox",
                                                    "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path"])
            try await client.request("attach", ["pid": target], timeout: .seconds(60))
            try await client.waitUntilInitialized(timeout: .seconds(30))
        } catch {
            client.terminate()
            throw error
        }
        var session = Session(client: client, pid: target, bundleID: bundleID)
        sessions[udid] = session
        var notes: [String] = []
        for spec in breakpoints {
            notes.append(try await addBreakpoint(&session, spec: spec, condition: nil))
        }
        sessions[udid] = session
        // Resumes the app, which was stopped by the attach.
        try await client.request("configurationDone")
        client.markRunning()
        scheduleIdleCheck(udid)
        var text = "Attached to \(bundleID) (pid \(target))\(relaunch ? ", relaunched under the debugger" : ""); it is running."
        if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
        return text
    }

    /// Adds (or with `remove`, removes) a breakpoint: "File.swift:42" or a function name.
    public func breakpoint(udid: String, spec: String, condition: String?, remove: Bool) async throws -> String {
        var session = try use(udid)
        defer { sessions[udid] = session }
        if remove {
            if let (file, line) = Self.fileLine(spec) {
                session.lineBreakpoints[file, default: []].removeAll { ($0["line"] as? Int) == line }
                try await setLineBreakpoints(session, file: file)
            } else {
                session.functionBreakpoints.removeAll { ($0["name"] as? String) == spec }
                try await setFunctionBreakpoints(session)
            }
            return "Removed the breakpoint at \(spec)."
        }
        return try await addBreakpoint(&session, spec: spec, condition: condition)
    }

    /// Waits up to `timeout` for the app to stop, and describes where.
    public func waitForStop(udid: String, timeout: Duration) async throws -> Stop? {
        let session = try use(udid)
        let state = try await session.client.waitUntilStopped(timeout: timeout)
        touch(udid)
        switch state {
        case .running:
            return nil
        case .ended(let why):
            sessions[udid] = nil
            throw SimBridgeError("The debug session ended: \(why).")
        case .stopped(let reason, let threadID, let description):
            let body = try await session.client.request("stackTrace", ["threadId": threadID, "levels": 8])
            let frames = body.objects("stackFrames").enumerated().map { index, frame in
                var name = frame.string("name") ?? "?"
                if name.count > 140 { name = name.prefix(140) + "…" }
                var line = "#\(index) \(name)"
                // Frames without a source file name their module and symbol
                // in "name" instead, which says nothing more.
                if let path = frame.object("source")?.string("path"), let number = frame.int("line"), number > 0 {
                    line += " at \((path as NSString).lastPathComponent):\(number)"
                }
                return line
            }
            return Stop(reason: reason, description: description, frames: frames)
        }
    }

    /// Evaluates an expression or lldb command in frame `frame` of the stopped thread.
    public func evaluate(udid: String, expression: String, frame: Int) async throws -> String {
        let session = try use(udid)
        guard case .stopped(_, let threadID, _) = session.client.state else {
            throw SimBridgeError("\(session.bundleID) is running; evaluate works only while it is paused. Call debug_wait for a breakpoint first.")
        }
        let trace = try await session.client.request("stackTrace", ["threadId": threadID, "levels": frame + 1])
        let frames = trace.objects("stackFrames")
        guard frame < frames.count, let frameID = frames[frame].int("id") else {
            throw SimBridgeError("The stopped thread has \(frames.count) frame(s); frame \(frame) does not exist.")
        }
        let result = try await session.client.request("evaluate", ["expression": expression, "frameId": frameID, "context": "repl"])
        return (result.string("result") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resumes the paused app.
    public func resume(udid: String) async throws -> String {
        let session = try use(udid)
        guard case .stopped(_, let threadID, _) = session.client.state else {
            return "\(session.bundleID) is already running."
        }
        try await session.client.request("continue", ["threadId": threadID])
        session.client.markRunning()
        return "Resumed \(session.bundleID)."
    }

    /// Detaches, leaving the app running.
    public func detach(udid: String) async {
        guard let session = sessions.removeValue(forKey: udid) else { return }
        _ = try? await session.client.request("disconnect", ["terminateDebuggee": false], timeout: .seconds(10))
        session.client.terminate()
    }

    /// Detaches every session; called when the server's client goes away.
    public func detachAll() async {
        for udid in sessions.keys { await detach(udid: udid) }
    }

    /// Why input and tree reads on `udid` would not work now, or nil.
    public func pausedNote(udid: String) -> String? {
        guard let session = sessions[udid], case .stopped(let reason, _, let description) = session.client.state else { return nil }
        return "\(session.bundleID) is paused in the debugger (\(description ?? reason)), so its screen is frozen and it takes no input. Call debug_continue first."
    }

    // MARK: - Internals

    private func use(_ udid: String) throws -> Session {
        guard var session = sessions[udid] else {
            throw SimBridgeError("No debug session on this simulator. Call debug_attach first.")
        }
        if case .ended(let why) = session.client.state {
            sessions[udid] = nil
            throw SimBridgeError("The debug session ended: \(why). Call debug_attach again.")
        }
        session.lastUse = .now
        sessions[udid] = session
        return session
    }

    private func touch(_ udid: String) { sessions[udid]?.lastUse = .now }

    private func scheduleIdleCheck(_ udid: String) {
        Task {
            while true {
                try? await Task.sleep(for: Self.idleLimit / 10)
                guard let session = sessions[udid] else { return }
                if ContinuousClock.now - session.lastUse >= Self.idleLimit {
                    Log.notice("detaching from \(session.bundleID) on \(udid): no debugger call in \(Self.idleLimit.inMilliseconds / 60000) minutes")
                    await detach(udid: udid)
                    return
                }
            }
        }
    }

    private func addBreakpoint(_ session: inout Session, spec: String, condition: String?) async throws -> String {
        var entry: [String: Any] = [:]
        if let condition, !condition.isEmpty { entry["condition"] = condition }
        if let (file, line) = Self.fileLine(spec) {
            entry["line"] = line
            session.lineBreakpoints[file, default: []].removeAll { ($0["line"] as? Int) == line }
            session.lineBreakpoints[file, default: []].append(entry)
            let results = try await setLineBreakpoints(session, file: file)
            let result = results.last { $0.int("line") == line } ?? results.last
            return Self.describe(result, spec: spec)
        }
        entry["name"] = spec
        session.functionBreakpoints.removeAll { ($0["name"] as? String) == spec }
        session.functionBreakpoints.append(entry)
        let results = try await setFunctionBreakpoints(session)
        return Self.describe(results.last, spec: spec)
    }

    @discardableResult
    private func setLineBreakpoints(_ session: Session, file: String) async throws -> [DAPObject] {
        let body = try await session.client.request("setBreakpoints", [
            "source": ["path": file, "name": (file as NSString).lastPathComponent],
            "breakpoints": session.lineBreakpoints[file] ?? [],
        ])
        return body.objects("breakpoints")
    }

    @discardableResult
    private func setFunctionBreakpoints(_ session: Session) async throws -> [DAPObject] {
        try await session.client.request("setFunctionBreakpoints", ["breakpoints": session.functionBreakpoints])
            .objects("breakpoints")
    }

    private static func describe(_ result: DAPObject?, spec: String) -> String {
        guard let result, (result["verified"] as? Bool) == true else {
            return "Breakpoint at \(spec) is set but resolves to no code yet (pending: wrong file or line, or code not loaded). Check the file name and line."
        }
        let at = result.int("line").map { " (line \($0))" } ?? ""
        return "Breakpoint at \(spec) is set\(at)."
    }

    /// "File.swift:42" split into file and line.
    static func fileLine(_ spec: String) -> (String, Int)? {
        guard let colon = spec.lastIndex(of: ":"), let line = Int(spec[spec.index(after: colon)...]), line > 0 else { return nil }
        let file = String(spec[..<colon])
        return file.isEmpty ? nil : (file, line)
    }

    /// Only apps the user installed can be debugged: system apps are signed
    /// against it, and debugging one can wedge the simulator.
    static func checkDebuggable(udid: String, bundleID: String) async throws {
        let output: Data
        do {
            output = try await Simctl.run(["get_app_container", udid, bundleID, "app"])
        } catch {
            throw SimBridgeError("\(bundleID) is not installed on this simulator.")
        }
        let path = String(decoding: output, as: UTF8.self)
        guard path.contains("/data/Containers/Bundle/Application/") else {
            throw SimBridgeError("\(bundleID) is a system app; glovebox debugs only apps you installed.")
        }
    }

    /// The pid of `bundleID` if it is running, from the simulator's launchd.
    static func runningPID(udid: String, bundleID: String) async throws -> Int? {
        let output = String(decoding: try await Simctl.run(["spawn", udid, "launchctl", "list"]), as: UTF8.self)
        for line in output.split(separator: "\n") where line.contains("UIKitApplication:\(bundleID)[") {
            if let pid = Int(line.split(separator: "\t").first ?? "") { return pid }
        }
        return nil
    }

    /// Refuses a process another debugger holds, naming Xcode if it is the one:
    /// relaunching would end that session, and attaching would fail.
    static func checkNotTraced(_ pid: Int, bundleID: String) throws {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return }
        guard info.kp_proc.p_flag & P_TRACED != 0 else { return }
        let holder = xcodeHoldsADebugger() ? "Xcode's debugger" : "another debugger"
        throw SimBridgeError("\(bundleID) (pid \(pid)) is already under \(holder). Stop debugging it there first; glovebox will not take it over.")
    }

    /// Whether some debugserver descends from Xcode (debugserver, then
    /// lldb-rpc-server, then Xcode).
    static func xcodeHoldsADebugger() -> Bool {
        guard let output = try? runProcess("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return false }
        var parent: [Int: Int] = [:]
        var name: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]), let ppid = Int(fields[1]) else { continue }
            parent[pid] = ppid
            name[pid] = String(fields[2])
        }
        for (pid, command) in name where command.hasSuffix("/debugserver") || command == "debugserver" {
            var current = parent[pid]
            var hops = 0
            while let next = current, next > 1, hops < 8 {
                if name[next]?.contains("/Xcode") == true || name[next]?.hasSuffix("Xcode") == true { return true }
                current = parent[next]
                hops += 1
            }
        }
        return false
    }

    private static func runProcess(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
