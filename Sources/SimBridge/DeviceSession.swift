import CoreGraphics
import Foundation
@_exported import SimBridgeObjC

/// Warm, in-process connection to one simulator. Holds the HID client, the
/// accessibility reader and the settle monitor, so an action costs one
/// in-process message instead of a process spawn.
public actor DeviceSession {
    public nonisolated let udid: String
    let device: SBDevice
    private var hidClient: SBHIDClient?
    private var coreDeviceHIDClient: SBCoreDeviceHIDClient?
    /// Whether the simulator runs dtuhidd, once known for this boot.
    var hidDaemonRunning: Bool?
    /// Whether the device has more than one built-in panel, once known.
    private var foldable: Bool?
    /// The hinge angle glovebox last set on this boot, if any.
    var hingeAngle: Double?
    private var accessibilityReader: SBAccessibility?
    private var monitor: SettleMonitor?
    /// Reading display properties costs ~20 ms of XPC, and the active display
    /// only changes when a foldable is folded, so it is reused briefly.
    private var cachedDisplay: (Display, ContinuousClock.Instant)?
    /// The boot the clients above were made for. Their ports die when the
    /// simulator shuts down, even if it boots again under the same UDID.
    private var bootedAt: Date?
    /// HID clients from earlier boots, kept alive on purpose (see `resetConnections`).
    private var retiredHIDClients: [SBHIDClient] = []
    private static let displayCacheLifetime: Duration = .seconds(2)
    /// What the last hit-test grid found, reused while the screen shows
    /// exactly the same pixels (see `addingRemoteElements`).
    var hitTestCache: HitTestCache?
    /// Hash of the last screenshot an interaction attached, so an identical
    /// one is not sent again (see `screenshotIfChanged`).
    var lastAttachedScreenshot: Int?
    /// Per app process, whether it reports frames in the framebuffer's
    /// orientation rather than the interface's (see `interfaceOriented(_:)`).
    var framebufferOrientedFrames: [FrameSpaceKey: Bool] = [:]

    private let inputLock = AsyncLock()

    private static let registry = Registry()

    /// Returns the cached session for `udid`, creating it on first use.
    public static func open(_ udid: String) async throws -> DeviceSession {
        try await registry.session(for: udid)
    }

    /// Drops the connections of `udid`'s session, if one is open, e.g. around
    /// a boot or an erase. The session itself stays: it keeps the HID clients
    /// of earlier boots alive (see `resetConnections`).
    public static func disconnect(_ udid: String) async {
        await registry.existing(udid)?.resetConnections()
    }

    init(device: SBDevice) {
        self.udid = device.udid
        self.device = device
    }

    public var name: String { device.name }
    public var isBooted: Bool { device.isBooted }

    // MARK: Display

    /// The display that is currently showing content. Foldable devices expose
    /// several built-in panels; only one shows content at a time. The open
    /// iPhone Duo reports its dark cover panel as lit and its inner panel as
    /// having no backlight, so a black framebuffer counts for more than the
    /// backlight.
    public func display() throws -> Display {
        guard device.isBooted else {
            throw SimBridgeError("\(device.name) is not booted. Call `boot` first.")
        }
        reconnectIfRebooted()
        if let (display, time) = cachedDisplay, ContinuousClock.now - time < Self.displayCacheLifetime {
            return display
        }
        let candidates = device.screens().compactMap(Display.init).filter { $0.isBuiltIn && $0.poweredOn }
        // Reading a framebuffer costs a round trip, so each is read once.
        let blank = candidates.count > 1 ? Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.isBlank) }) : [:]
        let ranked = candidates.sorted { a, b in
            let aBlank = blank[a.id] ?? false, bBlank = blank[b.id] ?? false
            if aBlank != bBlank { return !aBlank }
            if a.isLit != b.isLit { return a.isLit }
            return a.id < b.id
        }
        guard var display = ranked.first else {
            throw SimBridgeError("\(device.name) has no active display yet. Wait for it to finish booting.")
        }
        display.rotation = interfaceRotation(of: display.id)
        cachedDisplay = (display, .now)
        return display
    }

    /// How far `screenID`'s interface is rotated in its framebuffer, or 0 if
    /// the simulator can't say (before Xcode 27).
    private func interfaceRotation(of screenID: UInt32) -> Int {
        do {
            return try device.interfaceRotations()[NSNumber(value: screenID)]?.intValue ?? 0
        } catch {
            Log.debug("No interface rotation for display \(screenID): \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: Input lock

    /// Runs `body` while holding this device's input lock. Tool calls run
    /// concurrently and an interaction suspends between its touches and keys,
    /// so without the lock two calls would interleave their events. Reentrant
    /// within a task, so one call can hold it across several interactions.
    public nonisolated func withInputLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await inputLock.run(body)
    }

    // MARK: Lazily created clients

    func hid() throws -> SBHIDClient {
        reconnectIfRebooted()
        if let hidClient { return hidClient }
        let client = try SBHIDClient(device: device)
        hidClient = client
        return client
    }

    func coreDeviceHID() -> SBCoreDeviceHIDClient {
        reconnectIfRebooted()
        if let coreDeviceHIDClient { return coreDeviceHIDClient }
        let client = SBCoreDeviceHIDClient(device: device)
        coreDeviceHIDClient = client
        return client
    }

    /// How input reaches this device: "dtuhidd" (Xcode 27's in-simulator
    /// HID daemon) or "Indigo" (SimulatorKit's older HID path).
    public func inputTransport() -> String { hasHIDDaemon() ? "dtuhidd" : "Indigo" }

    /// Whether the simulator runs dtuhidd, Xcode 27's in-simulator HID
    /// daemon. Looked up once per boot.
    func hasHIDDaemon() -> Bool {
        reconnectIfRebooted()
        if let hidDaemonRunning { return hidDaemonRunning }
        let running = coreDeviceHID().isDaemonRunning
        hidDaemonRunning = running
        return running
    }

    /// Whether the device has more than one built-in panel, like the iPhone
    /// Duo. Fixed per device, so read once the simulator reports its panels.
    public var isFoldable: Bool {
        if let foldable { return foldable }
        let panels = device.screens().filter { $0.screenType == 0 }.count
        if panels > 0 { foldable = panels > 1 }
        return panels > 1
    }

    func accessibility() -> SBAccessibility {
        if let accessibilityReader { return accessibilityReader }
        let reader = SBAccessibility(device: device)
        accessibilityReader = reader
        return reader
    }

    /// The settle monitor for the active display, re-created when the active
    /// display changes (for example when a foldable is unfolded).
    func settleMonitor() throws -> SettleMonitor {
        let display = try display()
        if let monitor, monitor.displayID == display.id { return monitor }
        let newMonitor = SettleMonitor(display: display)
        monitor = newMonitor
        return newMonitor
    }

    /// Drops the HID client, settle monitor and display cache if the simulator
    /// has booted again since they were made, e.g. by Xcode or `simctl`.
    private func reconnectIfRebooted() {
        let current = device.lastBootedAt
        guard current != bootedAt else { return }
        if bootedAt != nil { Log.debug("\(device.name) rebooted; reconnecting") }
        bootedAt = current
        resetConnections()
    }

    /// Also called when a HID send fails, in case the reboot went unnoticed.
    func resetConnections() {
        // Releasing a client tells the simulator to disconnect its virtual HID
        // service. After a reboot that message reaches the new boot, and
        // backboardd aborts on the next event ("Unable to dispatch event
        // through disconnected service"), so old clients are never released.
        if let hidClient { retiredHIDClients.append(hidClient) }
        hidClient = nil
        // Unlike Indigo clients, dtuhidd connections can be closed at any
        // time: dtuhidd only removes the devices it made for them.
        coreDeviceHIDClient = nil
        hidDaemonRunning = nil
        hingeAngle = nil
        resetDisplay()
    }

    /// Drops the settle monitor and display cache but keeps the HID client,
    /// for when only the display port stopped delivering frames.
    func resetDisplay() {
        monitor = nil
        cachedDisplay = nil
        hitTestCache = nil
    }
}

extension DeviceSession {
    actor Registry {
        private var sessions: [String: DeviceSession] = [:]

        func session(for udid: String) throws -> DeviceSession {
            let key = udid.uppercased()
            if let session = sessions[key] { return session }
            let device = try SBDevice(udid: key)
            let session = DeviceSession(device: device)
            sessions[key] = session
            return session
        }

        func existing(_ udid: String) -> DeviceSession? {
            sessions[udid.uppercased()]
        }
    }
}

/// One simulator display with its geometry. Coordinates everywhere in glovebox
/// are in points, the space accessibility frames use. A display can draw its
/// interface rotated in its framebuffer, like the open iPhone Duo's inner
/// panel, so those points are converted for touches and screenshots.
public struct Display: Sendable {
    public let screen: SBScreen
    public let id: UInt32
    public let pixelSize: CGSize
    public let scale: Double
    /// The Indigo HID target that routes touches to this display. Mirrors
    /// SimulatorKit's SimDisplayView: TV-out and wireless displays use target
    /// 1, built-in panels are addressed by screen ID.
    let digitizerTarget: UInt32
    let isBuiltIn: Bool
    let poweredOn: Bool
    let isLit: Bool
    /// The interface's rotation in the framebuffer: 0, 90, 180 or 270
    /// degrees. With 90, the interface's top runs along the framebuffer's
    /// left edge.
    public internal(set) var rotation = 0

    /// Each property read is a round trip to the simulator, so they are all
    /// read once here rather than per touch.
    init?(_ screen: SBScreen) {
        let pixelSize = screen.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        self.screen = screen
        id = screen.screenID
        self.pixelSize = pixelSize
        let scale = screen.scale
        self.scale = scale > 0 ? scale : 1
        let type = screen.screenType
        isBuiltIn = type == 0
        digitizerTarget = (type == 1 || type == 2) ? 1 : id | 0x4000_0000
        poweredOn = screen.poweredOn
        isLit = screen.backlightState > 0
    }

    /// Size of the framebuffer in points.
    var framebufferSize: CGSize {
        CGSize(width: (pixelSize.width / scale).rounded(), height: (pixelSize.height / scale).rounded())
    }

    /// Size of the interface in points.
    public var size: CGSize {
        let size = framebufferSize
        return isSideways ? CGSize(width: size.height, height: size.width) : size
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    var isSideways: Bool { rotation == 90 || rotation == 270 }

    /// Converts an interface point to the 0...1 framebuffer ratio touch
    /// messages use, Indigo and dtuhidd alike.
    func ratio(for point: CGPoint) -> CGPoint {
        Self.ratio(for: point, interfaceSize: size, rotation: rotation)
    }

    static func ratio(for point: CGPoint, interfaceSize size: CGSize, rotation: Int) -> CGPoint {
        let x = point.x / size.width, y = point.y / size.height
        return switch rotation {
        case 90: CGPoint(x: y, y: 1 - x)
        case 180: CGPoint(x: 1 - x, y: 1 - y)
        case 270: CGPoint(x: 1 - y, y: x)
        default: CGPoint(x: x, y: y)
        }
    }

    /// Converts an interface point to the framebuffer-oriented point
    /// AXPTranslator hit-tests with.
    func accessibilityPoint(for point: CGPoint) -> CGPoint {
        let ratio = ratio(for: point)
        let size = framebufferSize
        return CGPoint(x: ratio.x * size.width, y: ratio.y * size.height)
    }

    /// The interface point for a framebuffer-oriented `point`, undoing
    /// `accessibilityPoint(for:)`.
    func interfacePoint(forAccessibility point: CGPoint) -> CGPoint {
        Self.interfacePoint(forRatio: CGPoint(x: point.x / framebufferSize.width, y: point.y / framebufferSize.height),
                            interfaceSize: size, rotation: rotation)
    }

    static func interfacePoint(forRatio r: CGPoint, interfaceSize size: CGSize, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: CGPoint(x: (1 - r.y) * size.width, y: r.x * size.height)
        case 180: CGPoint(x: (1 - r.x) * size.width, y: (1 - r.y) * size.height)
        case 270: CGPoint(x: r.y * size.width, y: (1 - r.x) * size.height)
        default: CGPoint(x: r.x * size.width, y: r.y * size.height)
        }
    }

    /// `element` and its descendants with frames reported in the
    /// framebuffer's orientation moved to interface points, rounded to 0.1
    /// as the simulator reports them.
    func interfaceOriented(_ element: AXElement) -> AXElement {
        func convert(_ point: CGPoint) -> CGPoint { interfacePoint(forAccessibility: point) }
        func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        var element = element
        let rect = element.rect
        if !rect.isNull {
            let a = convert(rect.origin), b = convert(CGPoint(x: rect.maxX, y: rect.maxY))
            element.frame = [min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y)].map(rounded)
        }
        if let activation = element.activation, activation.count == 2 {
            let point = convert(CGPoint(x: activation[0], y: activation[1]))
            element.activation = [rounded(point.x), rounded(point.y)]
        }
        element.children = element.children?.map(interfaceOriented)
        return element
    }

    /// Hash of the pixels on screen now (see `SBSurfaceContentHash`), or nil
    /// with no framebuffer.
    var contentHash: UInt64? {
        screen.framebuffer.map(SBSurfaceContentHash)
    }

    /// True when the framebuffer is entirely black, which is how a folded-away
    /// panel looks.
    var isBlank: Bool {
        guard let surface = screen.framebuffer else { return true }
        var grid = [UInt8](repeating: 0, count: 256)
        var columns = 0, rows = 0
        let cell = max(Int(surface.width), Int(surface.height)) / 15 + 1
        let count = SBSurfaceLuminanceGrid(surface, cell, &grid, grid.count, &columns, &rows)
        return count > 0 && grid[..<count].allSatisfy { $0 < 3 }
    }
}

public struct SimBridgeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }

    /// The text to show an agent for `error`. An NSError's description buries
    /// its message among the domain, code and user info, so NSErrors give
    /// their localized description; Swift errors give their own description.
    public static func message(for error: any Error) -> String {
        let nsError = error as NSError
        if type(of: error) is NSError.Type || nsError.userInfo[NSLocalizedDescriptionKey] != nil {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}
