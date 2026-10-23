import Foundation

/// How long to wait after an action before the next step runs.
public struct SettleOptions: Sendable {
    public enum Mode: String, Sendable {
        /// Wait until the framebuffer stops changing.
        case screen
        /// Like `screen`, then also wait for two identical accessibility snapshots.
        case ui
        /// Return as soon as the action is sent.
        case none
    }

    public var mode: Mode
    /// How long to wait for the first visible change. Apps take from ~20 ms
    /// (plain buttons) to ~150 ms (table cells) to start responding, and over
    /// 500 ms when busy. Only actions that change nothing wait this long.
    public var response: Duration
    /// How long the screen must stay unchanged, after changing, to count as settled.
    public var quiet: Duration
    /// Safety cap for screens that never stop animating.
    public var timeout: Duration

    public init(mode: Mode = .screen, response: Duration = .seconds(1), quiet: Duration = .milliseconds(250),
                timeout: Duration = .seconds(10)) {
        self.mode = mode
        self.response = response
        self.quiet = quiet
        self.timeout = timeout
    }
}

public struct SettleResult: Sendable {
    /// False when the timeout was hit while the screen was still changing.
    public let settled: Bool
    /// False when nothing visible changed within the response window.
    public let changed: Bool
    /// False when no frame at all arrived while waiting, so the display was not
    /// being observed and `changed` means nothing.
    public var observed = true
    /// Time from just before the action was sent until the screen settled.
    public let elapsed: Duration

    public var milliseconds: Int { elapsed.inMilliseconds }

    init(settled: Bool, changed: Bool, elapsed: Duration, observed: Bool = true) {
        self.settled = settled
        self.changed = changed
        self.elapsed = elapsed
        self.observed = observed
    }

    static let skipped = SettleResult(settled: true, changed: true, elapsed: .zero)
}

/// Watches one display's frames and reports when it stops changing.
///
/// Xcode 27 delivers a callback per rendered frame (no damage rectangles), so
/// each frame is reduced to a coarse luminance grid and compared with the
/// previous one. Changes confined to a caret-sized strip are ignored, so a
/// blinking text cursor does not keep the screen "busy". Grids are only
/// computed while someone is waiting.
final class SettleMonitor: @unchecked Sendable {
    /// Taken by `arm()`: when tracking started, the activity and frame
    /// counts then, and the screen's grid then.
    struct Mark {
        let generation: Int
        let time: ContinuousClock.Instant
        var frames = 0
        var baseline: [UInt8] = []
    }

    let displayID: UInt32
    private let screen: SBScreen
    private let cellSize: Int
    private let queue = DispatchQueue(label: "glovebox.settle")
    private var observer: UUID?

    // Guarded by `queue`.
    private var armed = 0
    private var grid: [UInt8] = []
    private var columns = 0
    private var generation = 0
    /// Frames delivered while armed, significant or not.
    private var frames = 0
    private var surfaceID: UInt32 = 0
    private var lastActivity = ContinuousClock.now
    private var activityWaiters: [UUID: Waiter] = [:]

    /// One `waitForActivity` call. Only touched on `queue`.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false

        /// Resumes the waiting task; later calls do nothing.
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    init(display: Display) {
        displayID = display.id
        screen = display.screen
        // About 8x8 points per cell: a caret spans one column, real content more.
        cellSize = max(8, Int(8 * display.scale))
        surfaceID = screen.framebufferID
        observer = screen.addFrameObserver(on: queue, frame: { [weak self] in
            self?.frameRendered()
        }, surfacesChanged: { [weak self] in
            self?.surfacesChanged()
        })
    }

    deinit {
        if let observer { screen.removeFrameObserver(observer) }
    }

    // MARK: Waiting

    /// Starts tracking changes. Call before sending the action so the first
    /// frames of its response are seen.
    func arm() -> Mark {
        Log.debug("arm display \(displayID)")
        return queue.sync {
            armed += 1
            if armed == 1 { captureBaseline() }
            return Mark(generation: generation, time: .now, frames: frames, baseline: grid)
        }
    }

    func disarm() {
        queue.sync { armed = max(0, armed - 1) }
    }

    /// Waits for the action's response in two phases: up to `response` after
    /// the action finished sending for the first significant change, then until
    /// nothing has changed for `quiet`. Sleeps only until the earliest moment
    /// the screen could be settled.
    func waitUntilSettled(after mark: Mark, actionEnded: ContinuousClock.Instant? = nil, options: SettleOptions) async -> SettleResult {
        let changed = await waitForActivity(after: mark.generation, until: (actionEnded ?? mark.time) + options.response)
        guard changed else {
            let framesSeen = queue.sync { frames } - mark.frames
            Log.debug("settle: no change; \(framesSeen) frame(s) arrived")
            return SettleResult(settled: true, changed: false, elapsed: ContinuousClock.now - mark.time,
                                observed: framesSeen > 0)
        }
        while true {
            let last = queue.sync { lastActivity }
            let now = ContinuousClock.now
            let idle = now - last
            if idle >= options.quiet {
                return SettleResult(settled: true, changed: true, elapsed: now - mark.time)
            }
            if now - mark.time >= options.timeout {
                return SettleResult(settled: false, changed: true, elapsed: now - mark.time)
            }
            let remaining = min(options.quiet - idle, options.timeout - (now - mark.time))
            do {
                try await Task.sleep(for: max(remaining, .milliseconds(5)))
            } catch {
                return SettleResult(settled: false, changed: true, elapsed: ContinuousClock.now - mark.time)
            }
        }
    }

    /// Whether a change too small to count as activity (see
    /// `isSignificantChange`) has lasted since `mark`. That covers a caret,
    /// but also a counter going from 1 to 2. Cells that differ from the
    /// baseline now are watched for up to `watch`: a caret blinks back to how
    /// it looked at the mark within one blink, while changed content stays
    /// changed. Returns as soon as every cell has matched again.
    func hasLastingSmallChange(since mark: Mark, watch: Duration) async -> Bool {
        let baseline = mark.baseline
        func differing(_ cells: [Int], in grid: [UInt8]) -> [Int] {
            guard grid.count == baseline.count else { return [] }
            return cells.filter { Self.differs(baseline[$0], grid[$0]) }
        }
        var cells = differing(Array(baseline.indices), in: queue.sync { grid })
        let deadline = ContinuousClock.now + watch
        while !cells.isEmpty, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: Self.moveInterval) } catch { return false }
            cells = differing(cells, in: queue.sync { grid })
        }
        Log.debug("settle: \(cells.count) cell(s) still differ from before the action")
        return !cells.isEmpty
    }

    /// How often `hasLastingSmallChange` looks at the latest grid: about once a frame.
    private static let moveInterval: Duration = .milliseconds(17)

    /// The current activity count, for `waitForActivity(after:until:)`.
    var currentGeneration: Int { queue.sync { generation } }

    /// Returns true as soon as a significant change has been drawn since
    /// `generation`, or false at `deadline` or when the task is cancelled.
    /// The monitor must be armed.
    func waitForActivity(after generation: Int, until deadline: ContinuousClock.Instant) async -> Bool {
        let id = UUID()
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    waiter.continuation = continuation
                    guard self.generation == generation, !waiter.cancelled else { return waiter.resume() }
                    self.activityWaiters[id] = waiter
                    let delay = max(0, (deadline - .now).timeInterval)
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.activityWaiters.removeValue(forKey: id)?.resume()
                    }
                }
            }
        } onCancel: {
            // In whichever order this and the block above run on `queue`, the
            // waiter resumes exactly once.
            queue.async {
                waiter.cancelled = true
                self.activityWaiters.removeValue(forKey: id)
                waiter.resume()
            }
        }
        return currentGeneration != generation
    }

    // MARK: Frame handling (on `queue`)

    private func frameRendered() {
        guard armed > 0 else { return }
        frames += 1
        guard let surface = screen.framebuffer else {
            Log.debug("frame on display \(displayID) without a framebuffer")
            return
        }
        let capacity = (Int(surface.width) / cellSize + 1) * (Int(surface.height) / cellSize + 1)
        var next = [UInt8](repeating: 0, count: capacity)
        var columns = 0, rows = 0
        let count = SBSurfaceLuminanceGrid(surface, cellSize, &next, capacity, &columns, &rows)
        guard count > 0 else {
            // Unknown pixel format: treat every frame as activity.
            noteActivity()
            return
        }
        next.removeSubrange(count...)
        defer {
            grid = next
            self.columns = columns
        }
        guard grid.count == next.count, self.columns == columns else {
            noteActivity()
            return
        }
        let significant = Self.isSignificantChange(from: grid, to: next, columns: columns)
        Log.debug("frame on display \(displayID): \(significant ? "significant" : "ignored")")
        if significant {
            noteActivity()
        }
    }

    /// Registering the observer delivers an initial callback, and property
    /// changes arrive here too, so only a replaced surface counts as activity.
    private func surfacesChanged() {
        let id = screen.framebufferID
        guard id != surfaceID else { return }
        Log.debug("framebuffer surface replaced on display \(displayID)")
        surfaceID = id
        guard armed > 0 else { return }
        captureBaseline()
        noteActivity()
    }

    private func captureBaseline() {
        grid = []
        columns = 0
        guard let surface = screen.framebuffer else { return }
        let capacity = (Int(surface.width) / cellSize + 1) * (Int(surface.height) / cellSize + 1)
        var baseline = [UInt8](repeating: 0, count: capacity)
        var columns = 0, rows = 0
        let count = SBSurfaceLuminanceGrid(surface, cellSize, &baseline, capacity, &columns, &rows)
        guard count > 0 else { return }
        baseline.removeSubrange(count...)
        grid = baseline
        self.columns = columns
    }

    private func noteActivity() {
        generation += 1
        lastActivity = .now
        let waiters = activityWaiters.values
        activityWaiters = [:]
        waiters.forEach { $0.resume() }
    }

    /// A change counts unless it fits in a caret-sized strip: at most two
    /// cells wide and eight tall (about 16 x 64 points).
    static func differs(_ old: UInt8, _ new: UInt8) -> Bool {
        abs(Int(old) - Int(new)) > 4
    }

    static func isSignificantChange(from old: [UInt8], to new: [UInt8], columns: Int) -> Bool {
        var minRow = Int.max, maxRow = -1, minColumn = Int.max, maxColumn = -1
        for index in old.indices where differs(old[index], new[index]) {
            let row = index / columns, column = index % columns
            minRow = min(minRow, row); maxRow = max(maxRow, row)
            minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
        }
        guard maxRow >= 0 else { return false }
        return maxColumn - minColumn >= 2 || maxRow - minRow >= 8
    }
}

extension Duration {
    public var inMilliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
