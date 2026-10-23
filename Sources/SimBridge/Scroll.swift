import CoreGraphics
import Foundation

/// Scrolling an element into view: swipe, look again, repeat.
public enum ScrollPlan {
    /// The part of the screen a nav bar covers, as a fraction of its height.
    static let topInset = 0.12
    /// The part a tab bar and home indicator cover.
    static let bottomInset = 0.15
    /// Lists bounce back a pixel or two at the end, so smaller moves than
    /// this mean the swipe moved nothing.
    public static let stillTolerance: Double = 4

    /// Where an element counts as in view on a screen of `size`: clear of the
    /// nav bar and tab bar insets.
    public static func visibleRegion(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: size.height * topInset, width: size.width,
               height: size.height * (1 - topInset - bottomInset))
    }

    public enum Step: Equatable, Sendable {
        /// The element is in view.
        case done
        /// Swipe the finger from `from` to `to`.
        case swipe(from: CGPoint, to: CGPoint)
    }

    /// What to do next. `element` is where the target is, if it is in the
    /// tree at all; `direction` is the finger's motion to use while it is
    /// not ("up" reveals content further down).
    public static func next(element: CGRect?, screen size: CGSize, direction: String) -> Step {
        let region = visibleRegion(in: size)
        let x = size.width / 2
        // A drag of most of the visible region, slow enough not to fling far.
        let span = region.height * 0.6
        guard let element, !element.isNull else {
            switch direction {
            case "down": return .swipe(from: CGPoint(x: x, y: region.midY - span / 2), to: CGPoint(x: x, y: region.midY + span / 2))
            case "left": return .swipe(from: CGPoint(x: size.width * 0.8, y: region.midY), to: CGPoint(x: size.width * 0.2, y: region.midY))
            case "right": return .swipe(from: CGPoint(x: size.width * 0.2, y: region.midY), to: CGPoint(x: size.width * 0.8, y: region.midY))
            default: return .swipe(from: CGPoint(x: x, y: region.midY + span / 2), to: CGPoint(x: x, y: region.midY - span / 2))
            }
        }
        if region.contains(element) || (element.height > region.height && element.intersects(region)) {
            return .done
        }
        if element.width <= size.width, element.minX < 0 || element.maxX > size.width, element.midY > region.minY, element.midY < region.maxY {
            // Off to a side, in a horizontal list.
            let distance = min(element.minX < 0 ? -element.minX + 16 : element.maxX - size.width + 16, size.width * 0.6)
            let sign: Double = element.minX < 0 ? 1 : -1
            return .swipe(from: CGPoint(x: x - sign * distance / 2, y: element.midY), to: CGPoint(x: x + sign * distance / 2, y: element.midY))
        }
        // Move the element's middle to the region's middle, at most `span` at a time.
        let offset = min(max(region.midY - element.midY, -span), span)
        return .swipe(from: CGPoint(x: x, y: region.midY - offset / 2), to: CGPoint(x: x, y: region.midY + offset / 2))
    }

    /// Whether a swipe moved anything: some element common to both reads
    /// moved by more than `stillTolerance`.
    public static func moved(before: [AXElement], after: [AXElement]) -> Bool {
        var frames: [String: CGRect] = [:]
        for element in before where element.label != nil || element.identifier != nil {
            frames[element.anchor] = element.rect
        }
        var common = 0
        for element in after {
            guard let old = frames[element.anchor] else { continue }
            common += 1
            if abs(old.minY - element.rect.minY) > stillTolerance || abs(old.minX - element.rect.minX) > stillTolerance {
                return true
            }
        }
        // Nothing in common: the whole screen changed.
        return common == 0
    }
}

extension DeviceSession {
    static func opposite(_ direction: String) -> String {
        switch direction {
        case "down": "up"
        case "left": "right"
        case "right": "left"
        default: "down"
        }
    }
}

extension AXElement {
    /// Identifies an element across reads regardless of where it is.
    var anchor: String { "\(role)|\(label ?? "")|\(identifier ?? "")" }
}

extension DeviceSession {
    /// Swipes until the element matching `query` is in view (clear of the
    /// nav and tab bars), then returns it. Lists drop rows scrolled out of
    /// view from the tree, so a target not yet seen may lie either way: at
    /// the end of the list in `direction`, the search turns around once.
    public func scroll(to query: ElementQuery, direction: String, maxSwipes: Int) async throws -> (AXElement, swipes: Int) {
        var direction = direction
        var turned = false
        var swipes = 0
        while true {
            try Task.checkCancellation()
            let elements = try await elements(for: query)
            let matches = elements.filter(query.matches)
            let target: AXElement? = matches.isEmpty ? nil : try query.pick(from: elements)
            let size = try display().size
            switch ScrollPlan.next(element: target?.rect, screen: size, direction: direction) {
            case .done:
                return (target!, swipes)
            case .swipe(let from, let to):
                guard swipes < maxSwipes else {
                    let state = target.map { "\($0.summary) is still out of view" } ?? "\(query.description) did not appear"
                    throw SimBridgeError("\(state) after \(swipes) swipe(s). Raise max_swipes, or try another direction.")
                }
                let distance = from.distance(to: to)
                let duration = Duration.milliseconds(max(400, Int(distance * 3)))
                _ = try await settled(SettleOptions()) { try await self.swipe(from: from, to: to, duration: duration) }
                swipes += 1
                let after = try await self.elements(for: query, waitUntilReady: false)
                guard !ScrollPlan.moved(before: elements, after: after) else { continue }
                // The last swipe moved nothing: as far as this list goes.
                if let found = after.first(where: query.matches) { return (found, swipes) }
                if !turned, target == nil {
                    turned = true
                    direction = Self.opposite(direction)
                    continue
                }
                throw SimBridgeError("Reached both ends of the list in \(swipes) swipe(s) without finding \(query.description). Check the query with describe_ui.")
            }
        }
    }
}
