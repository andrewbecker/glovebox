import CoreGraphics
import Foundation

/// Hardware buttons, as Indigo button event sources (values from idb) and,
/// where dtuhidd has one, a HID usage on the consumer page.
public enum HardwareButton: String, CaseIterable, Sendable {
    case home, lock, side, siri
    case applePay = "apple_pay"

    /// The usage dtuhidd's main-screen button service takes, or nil for
    /// buttons it has none for, which still go through Indigo.
    var consumerUsage: UInt16? {
        switch self {
        case .home: 0x40  // Menu
        case .lock, .side: 0x30  // Power
        // Consumer Voice Command (0xCF) does nothing; these are side-button
        // gestures (see `press(_:hold:)`).
        case .siri, .applePay: nil
        }
    }

    var source: UInt32 {
        switch self {
        case .home: 0x0
        case .lock: 0x1
        case .side: 0xBB8
        case .siri: 0x400002
        case .applePay: 0x1F4
        }
    }
}

// Every gesture below releases what it pressed if it fails or is cancelled
// partway, so the next action never starts with a finger or key still down.
extension DeviceSession {
    /// Indigo target for hardware buttons on iOS devices.
    private static let buttonTarget: UInt32 = 0x33
    private static let minimumButtonHold: Duration = .milliseconds(100)
    /// A tap's touch stays down this long. With none, UIKit can see the
    /// touch start and end together, which buttons accept but a switch
    /// ignores (2026-10-18, iOS 27.1; 17 ms was already enough).
    public static let tapHold: Duration = .milliseconds(50)
    /// SimulatorKit drops moves that follow the previous event within 16 ms.
    static let moveInterval: Duration = .milliseconds(17)
    /// A swipe sends at least this many moves between touching down and
    /// lifting: with too few, the guest reads the gesture as a tap
    /// (2026-10).
    static let minimumSwipeMoves = 20
    /// Fastest move rate for dtuhidd, which has no throttle of its own.
    static let fastMoveInterval: Duration = .milliseconds(8)

    // MARK: Touch

    public func tap(at point: CGPoint, hold: Duration = tapHold) async throws {
        let display = try checkedDisplay(containing: point)
        try await touch(.down, at: point, on: display)
        do {
            if hold > .zero { try await Task.sleep(for: hold) }
        } catch {
            try? await touch(.up, at: point, on: display)
            throw error
        }
        try await touch(.up, at: point, on: display)
    }

    /// How many moves a swipe of `duration` makes when moves may come no
    /// closer than `interval`: one per 17 ms, and at least
    /// `minimumSwipeMoves`, or as many as fit (Indigo drops moves closer than
    /// 16 ms, so there a short swipe gets fewer).
    static func swipeMoveCount(duration: Duration, interval: Duration) -> Int {
        let byTime = Int((duration / moveInterval).rounded(.down))
        let fitting = max(1, Int((duration / interval).rounded(.down)))
        return max(byTime, min(minimumSwipeMoves, fitting))
    }

    /// Drags from `start` to `end` over `duration`, with at least
    /// `minimumSwipeMoves` moves, about one every 17 ms for longer gestures.
    /// Short durations fling (scroll with momentum); long ones drag precisely.
    public func swipe(from start: CGPoint, to end: CGPoint, duration: Duration) async throws {
        let display = try checkedDisplay(containing: start)
        let interval = usesHIDDaemonForTouches ? Self.fastMoveInterval : Self.moveInterval
        try await touch(.down, at: start, on: display)
        var current = start
        do {
            let steps = Self.swipeMoveCount(duration: duration, interval: interval)
            let step = duration / steps
            // Moves follow a fixed schedule, so time spent sending does not
            // stretch the gesture and slow a fling, but never come closer
            // together than the throttle allows.
            let begin = ContinuousClock.now
            var lastSent = begin
            for index in 1...steps {
                try await Task.sleep(until: max(begin + step * index, lastSent + interval), clock: .continuous)
                lastSent = .now
                let t = Double(index) / Double(steps)
                current = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                try await touch(.move, at: current, on: display)
            }
        } catch {
            try? await touch(.up, at: current, on: display)
            throw error
        }
        try await touch(.up, at: end, on: display)
    }

    private func checkedDisplay(containing point: CGPoint) throws -> Display {
        let display = try display()
        guard display.bounds.contains(point) else {
            let size = display.size
            throw SimBridgeError(String(format: "Point (%.0f, %.0f) is outside the screen (%.0fx%.0f points).",
                                        point.x, point.y, size.width, size.height))
        }
        return display
    }

    /// Whether touches go through dtuhidd: whenever the simulator runs it.
    var usesHIDDaemonForTouches: Bool { hasHIDDaemon() }

    /// Touches go through dtuhidd when the simulator runs it, as Device Hub
    /// sends them. SimulatorHID then disconnects its built-in touch service
    /// and reconnects it on the next Indigo touch, but it tracks only one. A
    /// device with two built-in panels leaves the other disconnected, and an
    /// Indigo touch for it aborts backboardd ("Unable to dispatch event
    /// through disconnected service"), restarting SpringBoard and its apps.
    /// dtuhidd's touchscreens are always connected. Indigo touches remain for
    /// simulators without dtuhidd.
    private func touch(_ phase: SBTouchPhase, at point: CGPoint, on display: Display) async throws {
        let clamped = CGPoint(x: min(max(point.x, 0), display.size.width - 0.5),
                              y: min(max(point.y, 0), display.size.height - 0.5))
        if hasHIDDaemon() {
            do {
                try await sendCoreDeviceHID { try await $0.sendTouch(phase, ratio: display.ratio(for: clamped), display: display.id) }
                return
            } catch let error as SBError where error.code == .hidDaemonMissing {
                Log.debug("No dtuhidd (\(error.localizedDescription)); sending touches through Indigo")
                hidDaemonRunning = false
            }
        }
        do {
            try await sendHID { try await $0.sendTouch(phase, ratio: display.ratio(for: clamped), target: display.digitizerTarget) }
        } catch let error as SBError where error.code == .throttled && phase == .move {
            // A dropped intermediate move is harmless; the gesture continues.
        }
    }

    /// Sends one HID message. A failed send usually means the simulator
    /// restarted under a client made for the previous boot, so the connections
    /// are rebuilt and the message is sent once more.
    private func sendHID(_ send: (SBHIDClient) async throws -> Void) async throws {
        do {
            try await send(hid())
            return
        } catch let error as SBError where error.code == .throttled {
            throw error
        } catch {
            Log.debug("HID send failed (\(error)); reconnecting and retrying once")
            resetConnections()
        }
        do {
            try await send(hid())
        } catch {
            resetConnections()
            throw SimBridgeError("Could not send input to \(device.name) (\(SimBridgeError.message(for: error))). The simulator may have shut down or restarted: check list_devices, and call boot if it is not booted.")
        }
    }

    /// Sends one message to dtuhidd, retrying once on a fresh connection like
    /// `sendHID`. Throws SBError.hidDaemonMissing when there is no dtuhidd.
    private func sendCoreDeviceHID(_ send: (SBCoreDeviceHIDClient) async throws -> Void) async throws {
        do {
            try await send(coreDeviceHID())
            return
        } catch let error as SBError where error.code == .hidDaemonMissing {
            throw error
        } catch {
            Log.debug("dtuhidd send failed (\(error)); reconnecting and retrying once")
            resetConnections()
        }
        do {
            try await send(coreDeviceHID())
        } catch let error as SBError where error.code == .hidDaemonMissing {
            throw error
        } catch {
            resetConnections()
            throw SimBridgeError("Could not send input to \(device.name) (\(SimBridgeError.message(for: error))). The simulator may have shut down or restarted: check list_devices, and call boot if it is not booted.")
        }
    }

    // MARK: Keyboard

    /// Keys go through dtuhidd when the simulator runs it, since its
    /// SimulatorHID then ignores Indigo keys, and through Indigo otherwise.
    public func key(_ usage: UInt32, down: Bool) async throws {
        if hasHIDDaemon() {
            do {
                try await sendCoreDeviceHID { try await $0.sendKeyUsage(UInt16(truncatingIfNeeded: usage), down: down) }
                return
            } catch let error as SBError where error.code == .hidDaemonMissing {
                Log.debug("No dtuhidd (\(error.localizedDescription)); sending keys through Indigo")
                hidDaemonRunning = false
            }
        }
        try await sendHID { try await $0.sendKeyUsage(usage, down: down) }
    }

    /// Presses and releases `usage` while holding `modifiers`.
    public func press(_ usage: UInt32, modifiers: [UInt32] = [], hold: Duration = .zero) async throws {
        try await holding(modifiers + [usage]) {
            if hold > .zero { try await Task.sleep(for: hold) }
        }
    }

    /// Presses `usages` together: each goes down in order, then all are
    /// released in reverse.
    public func chord(_ usages: [UInt32]) async throws {
        try await holding(usages) {}
    }

    /// Presses `usages` in order, runs `body`, then releases them in reverse.
    /// Keys that went down are released even when something fails, so a
    /// modifier is never left held for later typing.
    private func holding(_ usages: [UInt32], _ body: () async throws -> Void) async throws {
        var down: [UInt32] = []
        var failure: (any Error)?
        do {
            for usage in usages {
                try await key(usage, down: true)
                down.append(usage)
            }
            try await body()
        } catch {
            failure = error
        }
        for usage in down.reversed() {
            do { try await key(usage, down: false) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Presses `usage` `count` times, leaving `Keyboard.gap(after:)` between
    /// presses so the guest sees each one.
    public func press(_ usage: UInt32, modifiers: [UInt32] = [], times count: Int) async throws {
        for press in 0..<max(1, count) {
            if press > 0 { try await Task.sleep(for: Keyboard.gap(after: usage)) }
            try await self.press(usage, modifiers: modifiers)
        }
    }

    /// Types `text` as hardware keystrokes. Parts with characters outside the
    /// US layout are pasted instead (see `Keyboard.segments(for:)`).
    public func type(_ text: String) async throws {
        var previous: UInt32?
        for segment in Keyboard.segments(for: text) {
            switch segment {
            case .keys(let strokes):
                for stroke in strokes {
                    if let previous { try await Task.sleep(for: Keyboard.gap(after: previous)) }
                    try await press(stroke.usage, modifiers: stroke.shift ? [Keyboard.leftShift] : [])
                    previous = stroke.usage
                }
            case .paste(let text):
                try await paste(text)
                previous = nil
            }
        }
    }

    /// Puts `text` on the simulator pasteboard and presses Cmd-V. The
    /// pasteboard is read back first: with Device Hub's shared clipboard on,
    /// the Mac's clipboard replaces the text at once, and Cmd-V would paste
    /// the person's own clipboard into the app instead.
    public func paste(_ text: String) async throws {
        try await Simctl.run(["pbcopy", udid], input: Data(text.utf8))
        guard try await Simctl.run(["pbpaste", udid]) == Data(text.utf8) else {
            throw SimBridgeError("Could not paste \"\(text)\": something replaced it on the simulator's pasteboard, most likely Device Hub's Use Shared Clipboard setting. Turn that off for this device, or type only characters on a US keyboard (others are pasted).")
        }
        try await press(Keyboard.usage(named: "v")!, modifiers: [Keyboard.leftCommand])
    }

    // MARK: Buttons

    /// Holding the side button this long calls Siri.
    private static let siriHold: Duration = .milliseconds(1500)
    /// The pause between the two presses of a double press (Apple Pay).
    private static let doublePressGap: Duration = .milliseconds(150)

    /// Unlike touches and keys, buttons ignore a press with no duration, so a
    /// press lasts at least `minimumButtonHold`.
    ///
    /// Buttons go through dtuhidd when the simulator runs it, Siri as a long
    /// press and Apple Pay as a double press of the side button. Indigo's
    /// Siri source crashed backboardd while dtuhidd ran (SimulatorHID overran
    /// a buffer building its vendor-defined event, Xcode 27.2, 2026-10-23),
    /// so no button goes through Indigo then.
    public func press(_ button: HardwareButton, hold: Duration = .zero) async throws {
        guard hasHIDDaemon() else {
            return try await pressButton(hold: max(hold, Self.minimumButtonHold)) { down in
                try await self.sendHID { try await $0.sendButtonSource(button.source, down: down, target: Self.buttonTarget) }
            }
        }
        let usage = button.consumerUsage ?? HardwareButton.side.consumerUsage!
        func power(down: Bool) async throws {
            try await sendCoreDeviceHID { try await $0.sendButton(usagePage: 0x0C, usage: usage, down: down) }
        }
        switch button {
        case .siri:
            try await pressButton(hold: max(hold, Self.siriHold), power)
        case .applePay:
            try await pressButton(hold: max(hold, Self.minimumButtonHold), power)
            try await Task.sleep(for: Self.doublePressGap)
            try await pressButton(hold: max(hold, Self.minimumButtonHold), power)
        default:
            try await pressButton(hold: max(hold, Self.minimumButtonHold), power)
        }
    }

    /// Presses with `send(true)`, holds, and releases with `send(false)`,
    /// releasing also when the wait is cancelled.
    private func pressButton(hold: Duration, _ send: (Bool) async throws -> Void) async throws {
        try await send(true)
        do {
            try await Task.sleep(for: hold)
        } catch {
            try? await send(false)
            throw error
        }
        try await send(false)
    }

    // MARK: Hinge

    /// The hinge moves in this many steps, like a hand on Device Hub's slider.
    /// Moves of 10 steps or fewer have wedged SpringBoard until a reboot
    /// (2026-10).
    static let hingeSweepSteps = 45
    private static let hingeStepInterval: Duration = .milliseconds(10)

    /// Sets a foldable's hinge angle in degrees: 0 is closed, 180 open flat.
    /// The hinge sweeps there from its last known angle; glovebox assumes it
    /// starts from whichever end matches the lit panel.
    public func setHinge(degrees: Double) async throws {
        guard isFoldable else {
            throw SimBridgeError("\(device.name) does not fold. Only devices with two built-in displays, like iPhone Duo, have a hinge.")
        }
        let target = min(max(degrees, 0), 180)
        let start = try hingeAngle ?? estimatedHingeAngle()
        do {
            for angle in Self.hingeSweep(from: start, to: target) {
                try await sendCoreDeviceHID { try await $0.sendHingeAngle(angle) }
                try await Task.sleep(for: Self.hingeStepInterval)
            }
            hingeAngle = target
        } catch let error as SBError where error.code == .hidDaemonMissing {
            throw SimBridgeError("Folding needs the HID daemon (dtuhidd) that Xcode 27 runs in simulators, and \(device.name) has none: \(error.localizedDescription)")
        }
        // The lit panel changes with the hinge.
        resetDisplay()
    }

    /// The angles of a sweep from `start` to `target`, ending on `target`.
    static func hingeSweep(from start: Double, to target: Double) -> [Double] {
        (1...hingeSweepSteps).map { start + (target - start) * Double($0) / Double(hingeSweepSteps) }
    }

    /// A guess at the hinge before glovebox has set it: open when the device
    /// shows content on its larger panel, closed otherwise.
    private func estimatedHingeAngle() throws -> Double {
        let current = try display()
        let largest = device.screens().compactMap(Display.init).filter(\.isBuiltIn)
            .max { $0.pixelSize.width * $0.pixelSize.height < $1.pixelSize.width * $1.pixelSize.height }
        return current.id == largest?.id ? 180 : 0
    }
}
