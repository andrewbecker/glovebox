import CoreGraphics
import Foundation

/// One node of the accessibility tree. Frames are in points.
public struct AXElement: Codable, Sendable, Equatable {
    public var role: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var placeholder: String?
    public var frame: [Double]
    /// Where VoiceOver activates the element, when that is not its center:
    /// e.g. the switch in a switch row.
    public var activation: [Double]?
    public var enabled: Bool
    public var truncated: Bool?
    /// True for elements found by hit-testing (see `HitTestGrid`) rather than
    /// the tree walk: content another process draws, such as a web page.
    public var hitTested: Bool?
    /// For a hit-tested element, the point it was found at, kept only when
    /// its reported frame does not contain that point: content drawn by
    /// another process, such as a home screen widget, can report frames in
    /// its own space. Then this, not the frame, is where it is.
    public var at: [Double]?
    /// Process ID, set on the root of a tree and on hit-test results.
    public var pid: Int?
    public var children: [AXElement]?

    public var rect: CGRect {
        guard frame.count == 4 else { return .null }
        return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }

    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Where to touch the element: where it was hit-tested if its frame is
    /// unreliable, else its activation point, else its center.
    public var tapPoint: CGPoint {
        if let at, at.count == 2 { return CGPoint(x: at[0], y: at[1]) }
        guard let activation, activation.count == 2 else { return center }
        return CGPoint(x: activation[0], y: activation[1])
    }

    /// Depth-first list of this element and its descendants.
    public var allElements: [AXElement] {
        var result: [AXElement] = []
        func visit(_ element: AXElement) {
            var node = element
            node.children = nil
            result.append(node)
            element.children?.forEach(visit)
        }
        visit(self)
        return result
    }

    /// Elements an agent can read or act on: anything with text or an
    /// identifier, plus controls. Bare layout containers are dropped.
    public var meaningfulElements: [AXElement] {
        allElements.filter { element in
            element.label != nil || element.value != nil || element.identifier != nil
                || element.placeholder != nil || Self.controlRoles.contains(element.role)
        }
    }

    static let controlRoles: Set<String> = [
        "Button", "TextField", "TextArea", "SearchField", "CheckBox", "Switch", "Slider",
        "PopUpButton", "MenuButton", "RadioButton", "Link", "Incrementor", "Tab",
    ]

    /// One line, e.g. `Button "About" id=general.about frame=(20,339,362,52)`.
    /// Frames are rounded to whole points: nothing an agent does needs
    /// tenths, and they cost tokens on every line (the json format keeps them).
    public var summary: String {
        var parts = [role]
        if let label { parts.append("\"\(label)\"") }
        if let value { parts.append("value=\"\(value)\"") }
        if let placeholder { parts.append("placeholder=\"\(placeholder)\"") }
        if let identifier { parts.append("id=\(identifier)") }
        func numbers(_ values: [Double]) -> String {
            values.map { $0.isFinite && abs($0) < 1e9 ? String(Int($0.rounded())) : "?" }.joined(separator: ",")
        }
        if let at, at.count == 2 {
            parts.append("at=(\(numbers(at)))")
        } else {
            parts.append("frame=(\(numbers(frame)))")
        }
        if !enabled { parts.append("disabled") }
        return parts.joined(separator: " ")
    }

    /// `summary`, marked "off-screen" when the element lies wholly outside
    /// `screen` (scrolled away), so an agent knows to scroll before tapping.
    public func summary(on screen: CGRect) -> String {
        let rect = at == nil ? self.rect : CGRect(origin: tapPoint, size: CGSize(width: 1, height: 1))
        guard !rect.isNull, !rect.intersects(screen) else { return summary }
        return summary + " off-screen"
    }

    /// What tells two reads of one element apart from two elements.
    var identity: String {
        "\(role)|\(label ?? "")|\(value ?? "")|\(identifier ?? "")|\(frame)"
    }

    /// Hash of what is visible to an agent, used to detect a stable UI.
    var contentSignature: Int {
        var hasher = Hasher()
        for element in allElements {
            hasher.combine(element.role)
            hasher.combine(element.label)
            hasher.combine(element.value)
            hasher.combine(element.frame)
        }
        return hasher.finalize()
    }
}

/// Selects elements by their accessibility attributes. String matches are
/// case-insensitive; every field that is set must match.
public struct ElementQuery: Sendable, Equatable {
    public var label: String?
    public var labelContains: String?
    public var identifier: String?
    public var role: String?
    public var value: String?
    public var valueContains: String?
    /// Matches label, value, placeholder or identifier containing this text.
    public var text: String?
    /// Which match to use when several match (0-based, in tree order).
    public var index: Int?

    public init(label: String? = nil, labelContains: String? = nil, identifier: String? = nil, role: String? = nil,
                value: String? = nil, valueContains: String? = nil, text: String? = nil, index: Int? = nil) {
        self.label = label
        self.labelContains = labelContains
        self.identifier = identifier
        self.role = role
        self.value = value
        self.valueContains = valueContains
        self.text = text
        self.index = index
    }

    /// The one element `self` selects from `elements`. Matches nested inside
    /// another match (a row's label inside the row) count once, as the outer
    /// one. Several distinct matches need an `index`.
    func pick(from elements: [AXElement]) throws -> AXElement {
        // The root carries the app's name as its label but is not a target.
        let all = elements.filter { matches($0) && ($0.role != "Application" || role != nil) }
        guard !all.isEmpty else {
            throw SimBridgeError(noMatchMessage(in: elements))
        }
        if let index {
            guard index >= 0 else {
                throw SimBridgeError("index must be 0 or more.")
            }
            guard index < all.count else {
                throw SimBridgeError("Only \(all.count) element(s) match \(description); index \(index) is out of range.")
            }
            return all[index]
        }
        // Drop each match that another one contains; of two with the same
        // frame, keep the first.
        func encloses(_ a: AXElement, _ b: AXElement) -> Bool { a.rect.insetBy(dx: -1, dy: -1).contains(b.rect) }
        let outer = all.indices.filter { i in
            !all.indices.contains { j in
                j != i && encloses(all[j], all[i]) && (!encloses(all[i], all[j]) || j < i)
            }
        }.map { all[$0] }
        guard outer.count == 1 else {
            let list = all.enumerated().map { "[\($0.offset)] \($0.element.summary)" }.joined(separator: "\n")
            throw SimBridgeError("\(all.count) elements match \(description), so none was picked. Narrow the query (e.g. add role or identifier) or pass index:\n\(list)")
        }
        return outer[0]
    }

    /// iOS names an agent is likely to use for roles the tree reports
    /// differently: a UISwitch comes through as CheckBox.
    static let roleAliases = ["switch": "CheckBox", "toggle": "CheckBox"]

    /// `text` with the no-break spaces iOS puts in labels (U+202F before AM
    /// and PM, U+00A0) made plain spaces, so a query typed with ordinary
    /// spaces still matches. describe_ui prints labels byte for byte.
    static func normalized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { noBreakSpaces.contains($0) }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { noBreakSpaces.contains($0) ? " " : $0 }))
    }

    private static let noBreakSpaces: Set<Unicode.Scalar> = ["\u{00A0}", "\u{2007}", "\u{202F}"]

    public var isEmpty: Bool {
        label == nil && labelContains == nil && identifier == nil && role == nil
            && value == nil && valueContains == nil && text == nil
    }

    public func matches(_ element: AXElement) -> Bool {
        func equal(_ a: String?, _ b: String?) -> Bool {
            guard let b else { return true }
            return a.map(Self.normalized)?.caseInsensitiveCompare(Self.normalized(b)) == .orderedSame
        }
        func contains(_ a: String?, _ b: String?) -> Bool {
            guard let b else { return true }
            return a.map(Self.normalized)?.localizedCaseInsensitiveContains(Self.normalized(b)) ?? false
        }
        let roleMatches = role.map { query in
            let wanted = query.hasPrefix("AX") ? String(query.dropFirst(2)) : query
            return element.role.caseInsensitiveCompare(wanted) == .orderedSame
                || element.role == Self.roleAliases[wanted.lowercased()]
        } ?? true
        let textMatches = text.map { query in
            [element.label, element.value, element.placeholder, element.identifier].contains { contains($0, query) }
        } ?? true
        return roleMatches && textMatches
            && equal(element.label, label) && contains(element.label, labelContains)
            && equal(element.identifier, identifier)
            && equal(element.value, value) && contains(element.value, valueContains)
    }

    /// The query with its one exact label, identifier or value loosened to a
    /// substring of any text, to suggest what a query that matched nothing
    /// meant: a SwiftUI stepper's buttons are labelled "Count: 0, Increment"
    /// with identifier "Increment".
    var loosened: ElementQuery? {
        let exact = [label, identifier, value].compactMap { $0 }
        guard exact.count == 1, text == nil else { return nil }
        var query = self
        query.label = nil
        query.identifier = nil
        query.value = nil
        query.text = exact[0]
        query.index = nil
        return query
    }

    /// Why nothing in `elements` matched, with up to three near matches.
    func noMatchMessage(in elements: [AXElement]) -> String {
        var message = "No element matches \(description)."
        if let loosened {
            let near = elements.filter(loosened.matches)
            if !near.isEmpty {
                message += " Similar: " + near.prefix(3).map(\.summary).joined(separator: "; ") + "."
            }
        }
        return message + " Call describe_ui to see what is on screen."
    }

    public var description: String {
        var parts: [String] = []
        if let label { parts.append("label=\"\(label)\"") }
        if let labelContains { parts.append("label_contains=\"\(labelContains)\"") }
        if let identifier { parts.append("identifier=\"\(identifier)\"") }
        if let role { parts.append("role=\(role)") }
        if let value { parts.append("value=\"\(value)\"") }
        if let valueContains { parts.append("value_contains=\"\(valueContains)\"") }
        if let text { parts.append("text=\"\(text)\"") }
        if let index { parts.append("index=\(index)") }
        return parts.joined(separator: " ")
    }
}

extension DeviceSession {
    /// How long a read keeps retrying an app that is not ready yet (on its
    /// launch screen, or no app frontmost) before reporting NOT READY.
    static let notReadyRetry: Duration = .seconds(6)

    /// Reads the frontmost app's accessibility tree. An app that is not ready
    /// is read again for up to `notReadyRetry` when `waitUntilReady`, which
    /// polling loops turn off since they retry themselves.
    public func accessibilityTree(maxElements: Int = 3000, waitUntilReady: Bool = true) async throws -> AXElement {
        let start = ContinuousClock.now
        while true {
            do {
                let json = try await accessibility().frontmostTree(withMaxElements: maxElements)
                return try await interfaceOriented(JSONDecoder().decode(AXElement.self, from: json))
            } catch let error as SBError where error.code == .notReady {
                guard waitUntilReady, ContinuousClock.now - start < Self.notReadyRetry else {
                    if !waitUntilReady { throw error }
                    throw SimBridgeError("\(error.localizedDescription) Still not ready after \(Self.notReadyRetry.inMilliseconds / 1000) s; wait_for an element of its first screen, or take a screenshot.")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Longest a hit-test grid may take before it stops with what it found.
    static let hitTestTimeLimit: TimeInterval = 2

    /// The frontmost app's tree, plus, with `includeRemote`, what a
    /// `HitTestGrid` finds that the walk missed (web content, alerts, the
    /// status bar), appended to the root and marked `hitTested`.
    public func accessibilityTree(maxElements: Int = 3000, waitUntilReady: Bool = true,
                                  includeRemote: Bool) async throws -> AXElement {
        let tree = try await accessibilityTree(maxElements: maxElements, waitUntilReady: waitUntilReady)
        return includeRemote ? try await addingRemoteElements(to: tree) : tree
    }

    /// `tree` with what the hit-test grid finds appended to its root. The
    /// grid's findings are reused while the screen holds exactly the same
    /// pixels and the walk the same elements, so describe_ui followed by a
    /// tap, or the two reads of a stable resolve, pay for one grid.
    func addingRemoteElements(to tree: AXElement) async throws -> AXElement {
        var tree = tree
        let display = try display()
        let points = HitTestGrid.points(for: tree, screen: display.size)
        guard !points.isEmpty else { return tree }
        let signature = tree.contentSignature
        let before = display.contentHash
        let found: [AXElement]
        if let cache = hitTestCache, let before, cache.matches(display: display.id, screen: before, tree: signature) {
            found = cache.elements
            Log.debug("hit-test: screen unchanged, reused \(found.count) element(s)")
        } else {
            let start = ContinuousClock.now
            let json = try await accessibility().elements(
                atPoints: points.map { NSValue(point: display.accessibilityPoint(for: $0)) },
                shownPoints: points.map { NSValue(point: $0) },
                displayID: display.id, containerRoles: HitTestGrid.containerRoles,
                timeLimit: Self.hitTestTimeLimit)
            let known = Set(tree.allElements.map(\.identity))
            found = try JSONDecoder().decode([AXElement].self, from: json).map { element in
                let at = element.at.map { CGPoint(x: $0[0], y: $0[1]) } ?? element.center
                var element = normalizedHit(element, shown: at, display: display)
                element.hitTested = true
                return element
            }.filter { $0.role != "Application" && !known.contains($0.identity) }
            // Reading order: hits arrive in grid order, subtrees in tree order.
            .sorted { ($0.tapPoint.y.rounded(), $0.tapPoint.x) < ($1.tapPoint.y.rounded(), $1.tapPoint.x) }
            Log.debug("hit-test: \(points.count) point(s) in \((ContinuousClock.now - start).inMilliseconds) ms found \(found.count) new element(s)")
            // Cached only if nothing redrew while the grid ran.
            let after = display.contentHash
            hitTestCache = before != nil && before == after
                ? HitTestCache(display: display.id, screen: before!, tree: signature, elements: found) : nil
        }
        tree.children = (tree.children ?? []) + found
        return tree
    }

    /// `tree` with frames in interface points. On a rotated panel some
    /// processes report frames in the framebuffer's orientation instead
    /// (SpringBoard on the open iPhone Duo's inner panel, 2026-10-23), so
    /// each process is checked once by hit-testing one of its elements both
    /// ways.
    func interfaceOriented(_ tree: AXElement) async throws -> AXElement {
        let display = try display()
        guard display.rotation != 0, let pid = tree.pid else { return tree }
        let key = FrameSpaceKey(pid: pid, display: display.id, rotation: display.rotation)
        if framebufferOrientedFrames[key] == nil, let found = await reportsFramebufferFrames(tree, display: display) {
            Log.debug("pid \(pid) reports frames in \(found ? "framebuffer" : "interface") orientation")
            framebufferOrientedFrames[key] = found
        }
        var tree = framebufferOrientedFrames[key] == true ? display.interfaceOriented(tree) : tree
        // The root's frame is the framebuffer's, or odder (SpringBoard's is
        // 466x678 on a 669x951 framebuffer), even when its children are in
        // interface points.
        tree.frame = [0, 0, display.size.width, display.size.height]
        return tree
    }

    /// Whether `tree`'s frames are in the framebuffer's orientation: one of
    /// its small leaves is hit-tested at its center read as an interface
    /// point, then as a framebuffer point. Nil if neither finds it.
    private func reportsFramebufferFrames(_ tree: AXElement, display: Display) async -> Bool? {
        var leaves: [AXElement] = []
        func visit(_ element: AXElement) {
            if let children = element.children, !children.isEmpty { return children.forEach(visit) }
            let rect = element.rect
            guard !rect.isNull, rect.width >= 4, rect.height >= 4, element.label != nil || element.identifier != nil,
                  !HitTestGrid.containerRoles.contains(element.role) else { return }
            leaves.append(element)
        }
        tree.children?.forEach(visit)
        for leaf in leaves.sorted(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }).prefix(3) {
            let center = leaf.center
            if let hit = try? await rawElement(atAccessibility: display.accessibilityPoint(for: center), shown: center, display: display),
               hit.identity == leaf.identity {
                return false
            }
            if let hit = try? await rawElement(atAccessibility: center, shown: center, display: display),
               hit.identity == leaf.identity {
                return true
            }
        }
        return nil
    }

    /// The element at a framebuffer-oriented point, its frame as reported.
    private func rawElement(atAccessibility point: CGPoint, shown: CGPoint, display: Display) async throws -> AXElement {
        let json = try await accessibility().element(at: point, displayID: display.id, shownPoint: shown)
        return try JSONDecoder().decode(AXElement.self, from: json)
    }

    /// A hit-test result in interface points. A frame that misses the
    /// point it was hit at may be in the framebuffer's orientation (then
    /// converted), or in the drawing process's own space (then the element
    /// keeps `at`, the point it was found at).
    func normalizedHit(_ element: AXElement, shown point: CGPoint, display: Display) -> AXElement {
        var element = element
        element.at = nil
        if display.rotation != 0, let pid = element.pid,
           let framebuffer = framebufferOrientedFrames[FrameSpaceKey(pid: pid, display: display.id, rotation: display.rotation)] {
            // A process checked already: its frames are trusted, even when
            // one misses the point (icons answer for their padding too).
            return framebuffer ? display.interfaceOriented(element) : element
        }
        let rect = element.rect.insetBy(dx: -1, dy: -1)
        if rect.contains(point) { return element }
        if display.rotation != 0, rect.contains(display.accessibilityPoint(for: point)) {
            let converted = display.interfaceOriented(element)
            if converted.rect.insetBy(dx: -1, dy: -1).contains(point) { return converted }
        }
        // Allow for an element that answers a little outside its frame.
        if element.rect.insetBy(dx: -HitTestGrid.spacing, dy: -HitTestGrid.spacing).contains(point) { return element }
        element.at = [point.x, point.y]
        return element
    }

    /// Process ID of the frontmost app (SpringBoard on the home screen).
    public func frontmostPID() async throws -> Int {
        try await accessibility().frontmostApplicationPID()
    }

    /// The deepest element at `point`.
    public func element(at point: CGPoint) async throws -> AXElement {
        let display = try display()
        let hit = try await rawElement(atAccessibility: display.accessibilityPoint(for: point), shown: point, display: display)
        return normalizedHit(hit, shown: point, display: display)
    }

    /// All elements matching `query`, in tree order.
    /// The hit-test grid runs only when the walk finds no match, so ordinary
    /// queries cost one walk.
    public func findElements(_ query: ElementQuery, waitUntilReady: Bool = true) async throws -> [AXElement] {
        try await elements(for: query, waitUntilReady: waitUntilReady).filter(query.matches)
    }

    /// The walked tree's elements, or, when none matches `query`, those plus
    /// what the hit-test grid finds. With `controlsFirst`, also hit-tests
    /// when the walk matched only text, so a query for a button hosted out
    /// of the walk's reach (the iPhone Duo's Settings sidebar) is not
    /// silently answered by a heading with the same words.
    func elements(for query: ElementQuery, waitUntilReady: Bool = true, controlsFirst: Bool = false) async throws -> [AXElement] {
        let tree = try await accessibilityTree(waitUntilReady: waitUntilReady)
        let walked = tree.allElements
        let matches = walked.filter(query.matches)
        let onlyText = controlsFirst && query.role == nil && query.index == nil
            && !matches.contains { AXElement.controlRoles.contains($0.role) }
        guard matches.isEmpty || onlyText else { return walked }
        return try await addingRemoteElements(to: tree).allElements
    }

    /// Resolves `query` to a single on-screen element, read from the tree as
    /// it is now. Several matches without an `index` are refused with the
    /// list, rather than guessing. With `stable`, the element must be in the
    /// same place on two reads in a row, so a control still sliding into
    /// place is not tapped where it was a moment ago.
    public func resolve(_ query: ElementQuery, stable: Bool = false) async throws -> AXElement {
        var element = try await resolveOnce(query)
        if stable {
            let deadline = ContinuousClock.now + Self.stabilityTimeout
            while true {
                let again = try await resolveOnce(query)
                if again.tapPoint.distance(to: element.tapPoint) <= 1 { break }
                Log.debug("resolve: \(query.description) moved from \(element.tapPoint) to \(again.tapPoint)")
                element = again
                guard ContinuousClock.now < deadline else {
                    throw SimBridgeError("\(element.summary) kept moving for \(Self.stabilityTimeout.inMilliseconds) ms, so it was not tapped. Wait for the screen to settle, then try again.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return try await checkReachable(element)
    }

    /// How long `resolve(_:stable:)` waits for a moving element to stop.
    static let stabilityTimeout: Duration = .seconds(3)

    private func resolveOnce(_ query: ElementQuery) async throws -> AXElement {
        try query.pick(from: try await elements(for: query, controlsFirst: true))
    }

    private func checkReachable(_ element: AXElement) async throws -> AXElement {
        let bounds = try display().bounds
        guard bounds.contains(element.tapPoint) else {
            throw SimBridgeError("\(element.summary) is off screen. Swipe to scroll it into view first.")
        }
        // A row scrolled under a tab bar is still on screen, but a tap at its
        // center would hit the bar. The element there should be the target, part
        // of it, or a container around it; anything else is on top of it.
        if let hit = try? await self.element(at: element.tapPoint), !hit.rect.contains(element.rect),
           !element.rect.insetBy(dx: -1, dy: -1).contains(hit.rect) {
            throw SimBridgeError("\(element.summary) is covered where it would be tapped by \(hit.summary). Swipe to scroll it clear first. If the element on top lets touches through, tap by x and y instead.")
        }
        return element
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

/// One app process on one panel orientation.
struct FrameSpaceKey: Hashable, Sendable {
    let pid: Int
    let display: UInt32
    let rotation: Int
}

/// A hit-test grid's findings and what they were found on.
struct HitTestCache: Sendable {
    let display: UInt32
    let screen: UInt64
    let tree: Int
    let elements: [AXElement]

    func matches(display: UInt32, screen: UInt64, tree: Int) -> Bool {
        self.display == display && self.screen == screen && self.tree == tree
    }
}

/// Where to hit-test for content the tree walk cannot reach. Web views,
/// Safari's pages, system alerts and the status bar draw from other
/// processes, so the frontmost app's tree has nothing for them, but asking
/// what is at a point finds them. Points already covered by an element from
/// the walk are skipped, which keeps the grid cheap on ordinary screens.
enum HitTestGrid {
    /// Spacing in points, about the size of the smallest touch target.
    static let spacing: Double = 50
    /// A childless group no taller than this (a tab bar or toolbar hosted by
    /// another process) gets a row of hit-tests along its middle, since the
    /// grid's rows can miss a bar that thin.
    static let barHeight: Double = 120

    /// Roles that hold other elements. Their rects say nothing about what is
    /// drawn: with children, the children cover their own parts; without,
    /// the container hosts content the walk did not reach (a web view, the
    /// iPhone Duo's Settings sidebar), even when it has a label.
    static let containerRoles: Set<String> = [
        "Application", "Window", "Group", "ScrollArea", "ScrollView", "Table", "List", "Outline",
        "Collection", "CollectionView", "WebArea", "SplitGroup", "LayoutArea", "TabGroup",
    ]

    /// The points to hit-test on a screen of `size` given the walked `tree`:
    /// grid points outside every walked leaf.
    static func points(for tree: AXElement, screen size: CGSize) -> [CGPoint] {
        var covering: [CGRect] = []
        var bars: [CGRect] = []
        let screen = CGRect(origin: .zero, size: size)
        func visit(_ element: AXElement) {
            let children = element.children ?? []
            children.forEach(visit)
            let rect = element.rect.intersection(screen)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
            guard children.isEmpty else { return }
            let hasContent = element.label != nil || element.value != nil || element.identifier != nil
                || AXElement.controlRoles.contains(element.role)
            if containerRoles.contains(element.role) || !hasContent {
                // A host for content the walk did not reach: it covers nothing.
                if rect.height <= barHeight { bars.append(rect) }
                return
            }
            covering.append(rect)
        }
        // The root (the app) never counts as covering the screen.
        tree.children?.forEach(visit)
        func uncovered(_ point: CGPoint) -> Bool { !covering.contains { $0.contains(point) } }
        var result: [CGPoint] = []
        var y = spacing / 2
        while y < size.height {
            var x = spacing / 2
            while x < size.width {
                let point = CGPoint(x: x, y: y)
                if uncovered(point) { result.append(point) }
                x += spacing
            }
            y += spacing
        }
        for bar in bars {
            var x = bar.minX + spacing / 4
            while x < bar.maxX {
                let point = CGPoint(x: x, y: bar.midY)
                if uncovered(point) { result.append(point) }
                x += spacing / 2
            }
        }
        return result
    }
}

