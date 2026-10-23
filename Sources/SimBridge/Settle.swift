import Darwin
import Foundation

extension DeviceSession {
    /// Least time from the end of one accessibility read to the start of the
    /// next while polling, so a screen that keeps animating does not keep the
    /// app's main thread busy answering reads.
    private static let pollInterval: Duration = .milliseconds(100)

    /// Longer than a text caret takes to blink back to how it looked, so a
    /// caret cannot pass for a small lasting change. On 2026-10-18 (iOS 27.1)
    /// a caret matched again within about 0.6 s of the response window ending.
    private static let caretBlink: Duration = .milliseconds(1100)

    /// Runs `action`, then waits for the screen to settle as `options` asks.
    /// Interactions only return once their effect has finished drawing, so the
    /// next screenshot or query sees the final screen without any fixed delay.
    /// Holds the input lock throughout, so concurrent interactions take turns.
    public func settled<T: Sendable>(_ options: SettleOptions, _ action: @Sendable () async throws -> T) async throws -> (T, SettleResult) {
        try await withInputLock { try await self.run(action, settling: options) }
    }

    private func run<T: Sendable>(_ action: @Sendable () async throws -> T, settling options: SettleOptions) async throws -> (T, SettleResult) {
        guard options.mode != .none else { return (try await action(), .skipped) }
        let monitor = try settleMonitor()
        let display = try display()
        let mark = monitor.arm()
        defer { monitor.disarm() }
        let before = display.contentHash
        let value = try await action()
        var screen = await monitor.waitUntilSettled(after: mark, actionEnded: .now, options: options)
        try Task.checkCancellation()
        // A screen with nothing animating (the iPhone Duo's home screen)
        // delivers no frames; its pixels show whether it changed.
        let frameless = !screen.observed && before != nil && before == display.contentHash
        if frameless { screen.observed = true }
        guard screen.observed else {
            // The screen changed without a frame arriving, so the monitor's
            // display port is dead. Rebuild it for the next action.
            resetDisplay()
            return (value, screen)
        }
        screen = await recheckWhenAppCatchesUp(monitor: monitor, mark: mark, after: screen, options: options)
        if frameless { screen.observed = true }
        try Task.checkCancellation()
        if !screen.changed, await monitor.hasLastingSmallChange(since: mark, watch: Self.caretBlink) {
            screen = SettleResult(settled: true, changed: true, elapsed: ContinuousClock.now - mark.time)
        }
        guard options.mode == .ui else { return (value, screen) }
        return (value, await waitForStableUI(monitor: monitor, mark: mark, after: screen, options: options))
    }

    /// An accessibility read slower than this means the app's main thread was
    /// busy. An idle app answered in 14 to 38 ms on 2026-10-18.
    private static let busyRead: Duration = .milliseconds(150)

    /// A busy app's screen goes still while its main thread works, which looks
    /// settled. The app serves accessibility reads on that same thread, so a
    /// read returns only once it has caught up (or after 5 s, when glovebox gives
    /// up on a hung app). Then:
    /// - If nothing changed within the response window, the input may have
    ///   waited behind the work; a change drawn shortly after is its effect,
    ///   not a miss.
    /// - If the screen changed and the read was slow, the app blocked after
    ///   drawing (e.g. a button's highlight, then its action), so the screen is
    ///   watched again for what it draws once unblocked.
    private func recheckWhenAppCatchesUp(monitor: SettleMonitor, mark: SettleMonitor.Mark, after screen: SettleResult,
                                         options: SettleOptions) async -> SettleResult {
        let start = ContinuousClock.now
        let generation = monitor.currentGeneration
        _ = try? await accessibilityTree(maxElements: 1, waitUntilReady: false)
        let read = ContinuousClock.now - start
        Log.debug("settle: app answered an accessibility read after \(read.inMilliseconds) ms")
        var grace = options
        grace.response = min(options.response, .milliseconds(300))
        guard screen.changed else {
            return await monitor.waitUntilSettled(after: mark, actionEnded: .now, options: grace)
        }
        guard read >= Self.busyRead else { return screen }
        grace.timeout = options.timeout - (start - mark.time)
        let after = await monitor.waitUntilSettled(after: SettleMonitor.Mark(generation: generation, time: start),
                                                   actionEnded: .now, options: grace)
        return SettleResult(settled: after.settled, changed: true, elapsed: ContinuousClock.now - mark.time)
    }

    /// Waits until two consecutive accessibility snapshots agree, which catches
    /// content that changes without visible animation.
    private func waitForStableUI(monitor: SettleMonitor, mark: SettleMonitor.Mark, after screen: SettleResult,
                                 options: SettleOptions) async -> SettleResult {
        var previous = try? await accessibilityTree(waitUntilReady: false).contentSignature
        var changed = screen.changed
        while ContinuousClock.now - mark.time < options.timeout, !Task.isCancelled {
            let generation = monitor.currentGeneration
            let current = try? await accessibilityTree(waitUntilReady: false).contentSignature
            if current == previous {
                return SettleResult(settled: screen.settled, changed: changed, elapsed: ContinuousClock.now - mark.time)
            }
            changed = true
            previous = current
            let next = SettleMonitor.Mark(generation: generation, time: .now)
            var remaining = options
            remaining.timeout = options.timeout - (ContinuousClock.now - mark.time)
            _ = await monitor.waitUntilSettled(after: next, options: remaining)
        }
        return SettleResult(settled: false, changed: changed, elapsed: ContinuousClock.now - mark.time)
    }

    /// Waits until an element matching `query` appears (or, with `gone`,
    /// disappears), then for the screen to settle. Re-checks when the screen
    /// changes rather than on a fixed timer, with a 1 s backstop for changes
    /// that are not drawn.
    public func waitFor(_ query: ElementQuery, gone: Bool, timeout: Duration,
                        quiet: Duration = .milliseconds(250)) async throws -> (AXElement?, Duration) {
        let monitor = try settleMonitor()
        let mark = monitor.arm()
        defer { monitor.disarm() }
        while true {
            try Task.checkCancellation()
            let generation = monitor.currentGeneration
            let lookup = ContinuousClock.now
            let matches: [AXElement]
            do {
                matches = try await findElements(query, waitUntilReady: false)
            } catch {
                Log.debug("wait_for: accessibility read failed after \((ContinuousClock.now - lookup).inMilliseconds) ms: \(error)")
                matches = []
            }
            let readEnd = ContinuousClock.now
            Log.debug("wait_for: \(matches.count) match(es), read took \((readEnd - lookup).inMilliseconds) ms")
            let elapsed = readEnd - mark.time
            if gone ? matches.isEmpty : !matches.isEmpty {
                // The tree updates before transitions finish drawing; let them land.
                // Both windows count from `mark`, so `timeout` stays the overall cap.
                if monitor.currentGeneration != mark.generation {
                    _ = await monitor.waitUntilSettled(after: mark, options: SettleOptions(response: .zero, quiet: quiet, timeout: timeout))
                }
                return (matches.first, ContinuousClock.now - mark.time)
            }
            guard elapsed < timeout else {
                let what = gone ? "disappear" : "appear"
                throw SimBridgeError("Timed out after \(elapsed.inMilliseconds) ms waiting for \(query.description) to \(what).")
            }
            _ = await monitor.waitForActivity(after: generation, until: .now + min(.seconds(1), timeout - elapsed))
            try await Task.sleep(until: min(readEnd + Self.pollInterval, mark.time + timeout), clock: .continuous)
        }
    }

    /// Waits until process `pid` is the frontmost app and exposes some UI, then
    /// for its screen to settle. Used after launching an app: it is frontmost
    /// while still showing a blank launch screen that would otherwise look settled.
    /// A launch transition is over by then, so what is still in front of
    /// the app is something else: a system alert, typically.
    static let alertGrace: Duration = .seconds(2)

    /// How long a launched app's first screen must hold still. Cold
    /// launches pause mid-transition: 2.2 to 2.3 s in Photos on iOS 26.5
    /// before its What's New sheet slides in (measured 2026-10-23); 3.5 s
    /// leaves margin. Taps keep the short window.
    public static let launchQuiet: Duration = .milliseconds(3500)

    public func waitUntilFrontmost(pid: Int, timeout: Duration) async throws -> SettleResult {
        try await waitUntilFrontmostOrAlert(pid: pid, timeout: timeout).0
    }

    /// Like `waitUntilFrontmost`, but returns early when a system alert (a
    /// permission prompt, say) stays in front of the app: the app launched,
    /// and waiting longer would not help. The alert is described for the agent.
    public func waitUntilFrontmostOrAlert(pid: Int, timeout: Duration,
                                          quiet: Duration = launchQuiet) async throws -> (SettleResult, alert: String?) {
        let monitor = try settleMonitor()
        let mark = monitor.arm()
        defer { monitor.disarm() }
        while true {
            try Task.checkCancellation()
            let generation = monitor.currentGeneration
            let frontmost = try? await frontmostPID()
            var hasContent = false
            var alert: String?
            if frontmost == pid, let tree = try? await accessibilityTree(maxElements: 5, waitUntilReady: false) {
                hasContent = tree.pid == pid && tree.children?.isEmpty == false
            } else if let frontmost, ContinuousClock.now - mark.time >= Self.alertGrace, Self.isSpringBoard(frontmost),
                      let tree = try? await accessibilityTree(maxElements: 60, waitUntilReady: false) {
                alert = Self.alertSummary(tree)
            }
            let readEnd = ContinuousClock.now
            Log.debug("launch: frontmost pid \(frontmost.map(String.init) ?? "-"), content \(hasContent)")
            let elapsed = readEnd - mark.time
            if hasContent {
                let result = await monitor.waitUntilSettled(after: SettleMonitor.Mark(generation: generation, time: .now),
                                                            options: SettleOptions(quiet: quiet, timeout: max(.zero, timeout - elapsed)))
                return (SettleResult(settled: result.settled, changed: true, elapsed: ContinuousClock.now - mark.time), nil)
            }
            if let alert {
                return (SettleResult(settled: true, changed: true, elapsed: elapsed), alert)
            }
            guard elapsed < timeout else {
                throw SimBridgeError("Process \(pid) did not become the frontmost app within \(elapsed.inMilliseconds) ms (frontmost pid: \(frontmost.map(String.init) ?? "unknown")).")
            }
            _ = await monitor.waitForActivity(after: generation, until: .now + min(.seconds(1), timeout - elapsed))
            try await Task.sleep(until: min(readEnd + Self.pollInterval, mark.time + timeout), clock: .continuous)
        }
    }

    /// Whether `pid` is a simulator's SpringBoard, which hosts system alerts
    /// (permission prompts) over apps. Simulator processes are Mac processes,
    /// so their path is readable from here.
    static func isSpringBoard(_ pid: Int) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self).hasSuffix("/SpringBoard.app/SpringBoard")
    }

    /// "<text>" with buttons [A] [B], when `tree` looks like an alert: a
    /// few buttons and some text, unlike the home screen's rows of icons.
    static func alertSummary(_ tree: AXElement) -> String? {
        let elements = tree.meaningfulElements
        let buttons = elements.filter { $0.role == "Button" }.compactMap(\.label)
        let texts = elements.filter { $0.role == "StaticText" }.compactMap(\.label)
        guard (1...4).contains(buttons.count), !texts.isEmpty, elements.count <= 12 else { return nil }
        return "\"" + texts.joined(separator: " ") + "\" with buttons " + buttons.map { "[\($0)]" }.joined(separator: " ")
    }
}
