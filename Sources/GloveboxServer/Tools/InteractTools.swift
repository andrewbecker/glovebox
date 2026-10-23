import CoreGraphics
import Foundation
import MCP
import SimBridge

/// Touch gestures and hardware buttons. Every interaction waits for the screen
/// to settle before returning (see the settle_* arguments).
enum InteractTools {
    static var all: [ToolEntry] {
        [tap, longPress, swipe, scrollTo, pressButton, shake, fold]
    }

    /// Where to touch: explicit x/y, or the element the query selects (see `AXElement.tapPoint`).
    static func target(_ args: Arguments, session: DeviceSession) async throws -> (CGPoint, String) {
        if let point = args.point() {
            return (point, point.text)
        }
        let query = args.query
        guard !query.isEmpty else {
            throw ToolError("Pass x and y, or an element query such as label or identifier.")
        }
        let element = try await session.resolve(query, stable: args.requiresStableTarget)
        return (element.tapPoint, "\(element.summary) at \(element.tapPoint.text)")
    }

    static let tap = ToolEntry(
        tool: Tool(
            name: "tap",
            description: "Tap at x/y, or where VoiceOver would on the element matching a query (every given field must match): its center, or the switch in a switch row. Several matches are refused with a numbered list; pass index to pick one. \(coordinateContract) \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.query, Schema.index, Schema.settle, [
                "udid": Schema.udid,
                "x": Schema.number("X in points."),
                "y": Schema.number("Y in points."),
            ]))
        ),
        handler: { args in
            try await args.interaction { session in
                let (point, description) = try await target(args, session: session)
                let (_, settle) = try await session.settled(try args.settleOptions()) {
                    try await session.tap(at: point)
                }
                return await args.result("Tapped \(description).\(settle.note)", session: session)
            }
        }
    )

    static let longPress = ToolEntry(
        tool: Tool(
            name: "long_press",
            description: "Touch and hold at x/y or on the element matching a query. \(coordinateContract) \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.query, Schema.index, Schema.settle, [
                "udid": Schema.udid,
                "x": Schema.number("X in points."),
                "y": Schema.number("Y in points."),
                "duration_ms": Schema.number("How long to hold (default 1000)."),
            ]))
        ),
        handler: { args in
            try await args.interaction { session in
                let (point, description) = try await target(args, session: session)
                let hold = args.milliseconds("duration_ms") ?? .seconds(1)
                let (_, settle) = try await session.settled(try args.settleOptions()) {
                    try await session.tap(at: point, hold: hold)
                }
                return await args.result("Long-pressed \(description).\(settle.note)", session: session)
            }
        }
    )

    static let swipe = ToolEntry(
        tool: Tool(
            name: "swipe",
            description: "Drag a finger across the screen: from_x/from_y to to_x/to_y, or a direction, the finger's motion (\"up\" brings content further down into view). To bring an element into view, use scroll_to. \(coordinateContract) \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "from_x": Schema.number("Start X in points."),
                "from_y": Schema.number("Start Y in points."),
                "to_x": Schema.number("End X in points."),
                "to_y": Schema.number("End Y in points."),
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"],
                              "description": "Swipe this way from the screen center, or from x/y."],
                "x": Schema.number("Start X for a direction swipe."),
                "y": Schema.number("Start Y for a direction swipe."),
                "distance": Schema.number("Fraction of the screen a direction swipe travels (default 0.5)."),
                "duration_ms": Schema.number("Default 300. Short swipes fling; long ones drag precisely."),
            ]))
        ),
        handler: { args in
            try await args.interaction { session in
                let (start, end) = try await endpoints(args, session: session)
                let duration = args.milliseconds("duration_ms") ?? .milliseconds(300)
                let (_, settle) = try await session.settled(try args.settleOptions()) {
                    try await session.swipe(from: start, to: end, duration: duration)
                }
                return await args.result("Swiped from \(start.text) to \(end.text).\(settle.note)", session: session)
            }
        }
    )

    private static func endpoints(_ args: Arguments, session: DeviceSession) async throws -> (CGPoint, CGPoint) {
        if let start = args.point(x: "from_x", y: "from_y"), let end = args.point(x: "to_x", y: "to_y") {
            return (start, end)
        }
        guard let direction = args.string("direction") else {
            throw ToolError("Pass from_x, from_y, to_x and to_y, or a direction.")
        }
        let size = try await session.display().size
        let start = args.point() ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let fraction = args.double("distance") ?? 0.5
        let (dx, dy): (Double, Double) = switch direction {
        case "up": (0, -size.height * fraction)
        case "down": (0, size.height * fraction)
        case "left": (-size.width * fraction, 0)
        case "right": (size.width * fraction, 0)
        default: throw ToolError("direction must be up, down, left or right.")
        }
        let end = CGPoint(x: min(max(start.x + dx, 1), size.width - 1), y: min(max(start.y + dy, 1), size.height - 1))
        return (start, end)
    }

    static let scrollTo = ToolEntry(
        tool: Tool(
            name: "scroll_to",
            description: "Swipe until the element matching a query is in view, clear of the nav and tab bars. Turns back once at the end of the list. direction is the finger's motion until the element is in the tree; then glovebox swipes toward it. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.query, Schema.index, Schema.settle, [
                "udid": Schema.udid,
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"],
                              "description": "Finger motion while searching (default up: content further down)."],
                "max_swipes": Schema.integer("Give up after this many swipes (default 10, at most 50)."),
            ]))
        ),
        handler: { args in
            let query = args.query
            guard !query.isEmpty else { throw ToolError("Pass an element query such as label or identifier.") }
            let direction = args.string("direction") ?? "up"
            guard ["up", "down", "left", "right"].contains(direction) else {
                throw ToolError("direction must be up, down, left or right.")
            }
            let maxSwipes = min(max(0, args.int("max_swipes") ?? 10), 50)
            return try await args.interaction { session in
                let (element, swipes) = try await session.scroll(to: query, direction: direction, maxSwipes: maxSwipes)
                let how = swipes == 0 ? "already in view" : "in view after \(swipes) swipe(s)"
                return await args.result("\(element.summary) is \(how).", session: session)
            }
        }
    )

    static let shake = ToolEntry(
        tool: Tool(
            name: "shake",
            description: "Shake the device (a UIKit shake event, as Device Hub sends), e.g. for shake-to-undo or a debug menu. Check the screenshot: nothing reports whether an app listened. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, ["udid": Schema.udid]))
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let session = try await DeviceSession.open(udid)
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await Simctl.run(["spawn", udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
            }
            return await args.result("Shook the device.\(settle.note)", session: session)
        }
    )

    static let pressButton = ToolEntry(
        tool: Tool(
            name: "press_button",
            description: "Press a hardware button. home returns to the home screen; lock (or side) toggles sleep; siri holds the side button; apple_pay double-presses it. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "button": ["type": "string", "enum": .array(HardwareButton.allCases.map { .string($0.rawValue) })],
                "duration_ms": Schema.number("Hold the button this long (default 100, the shortest press iOS registers)."),
            ]), required: ["button"])
        ),
        handler: { args in
            let name = try args.require("button")
            guard let button = HardwareButton(rawValue: name) else {
                throw ToolError("Unknown button '\(name)'. Use one of: \(HardwareButton.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let hold = args.milliseconds("duration_ms") ?? .zero
            let session = try await args.session()
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await session.press(button, hold: hold)
            }
            return await args.result("Pressed \(name).\(settle.note)", session: session)
        }
    )

    static let fold = ToolEntry(
        tool: Tool(
            name: "fold",
            description: "Set the hinge of a foldable such as iPhone Duo: 0 closes it, 180 opens it flat. It sweeps there in small steps, as a hand would; afterwards glovebox works with whichever panel shows content. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "angle": Schema.number("Hinge angle in degrees, from 0 (closed) to 180 (open flat)."),
            ]), required: ["angle"])
        ),
        handler: { args in
            guard let angle = args.double("angle") else {
                throw ToolError("Missing required argument 'angle' (degrees, 0 to 180).")
            }
            guard (0...180).contains(angle) else {
                throw ToolError("angle must be from 0 (closed) to 180 (open flat).")
            }
            let session = try await args.session()
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await session.setHinge(degrees: angle)
            }
            return await args.result("Set the hinge to \(String(format: "%g", angle))°.\(settle.note)", session: session)
        }
    )
}
