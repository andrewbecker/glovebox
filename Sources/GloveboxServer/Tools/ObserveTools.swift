import Foundation
import MCP
import SimBridge

/// Reading the screen: pixels and the accessibility tree.
enum ObserveTools {
    static var all: [ToolEntry] {
        [screenshot, describeUI, describePoint, findElements, waitFor]
    }

    static let defaultElementLimit = 400
    static let maxElementLimit = 2000

    static let screenshot = ToolEntry(
        tool: Tool(
            name: "screenshot",
            description: "Capture the simulator screen. Interactions already attach one, so call this only to look again. At the default scale 1, coordinates read off the image can be passed to tap and swipe as they are. \(coordinateContract)",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "scale": Schema.number("Image pixels per point (default 1). 0.5 saves tokens; the device scale (e.g. 3) gives full resolution."),
                "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Image format (default jpeg)."],
                "quality": Schema.number("JPEG quality from 0 to 1 (default 0.8)."),
                "save_path": Schema.string("Also save the image to this new file, under $TMPDIR or /tmp. Never overwrites."),
            ])
        ),
        handler: { args in
            let session = try await args.session()
            guard let format = Screenshot.Format(rawValue: args.string("format") ?? "jpeg") else {
                throw ToolError("format must be jpeg or png.")
            }
            let shot = try await session.screenshot(scale: args.double("scale") ?? 1, format: format, quality: args.double("quality") ?? 0.8)
            // Asked for, so always attached; recorded so the next action's
            // identical screen is not sent again.
            _ = await session.recordSent(shot)
            let size = shot.pointSize
            var text = "Screen is \(Int(size.width))x\(Int(size.height)) points; image is \(shot.pixelWidth)x\(shot.pixelHeight) px."
            if let paused = await Debugger.shared.pausedNote(udid: session.udid) { text += " Frozen: " + paused }
            if let path = args.string("save_path") {
                text += " Saved to \(try CapturePath.write(shot.data, to: path))."
            }
            return [.image(shot), .plain(text)]
        }
    )

    static let describeUI = ToolEntry(
        tool: Tool(
            name: "describe_ui",
            description: "Describe the frontmost app's UI from its accessibility tree: role, label, value, identifier and frame (x, y, width, height) for each element. Labels are printed byte for byte, so copy them exactly. Cheaper and more precise than a screenshot for finding things to tap. Content drawn by other processes (web pages, system alerts, the status bar) is found by hit-testing the screen. \(coordinateContract)",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "format": ["type": "string", "enum": ["compact", "all", "json"],
                           "description": "compact (default): elements with text, an identifier or a control role, one per line. all: every element, indented by depth. json: the nested tree."],
                "include_web": Schema.boolean("Hit-test for content the tree walk misses: web views, alerts, the status bar (default true)."),
                "max_elements": Schema.integer("Most elements to list (default \(defaultElementLimit), at most \(maxElementLimit))."),
            ])
        ),
        handler: { args in
            let session = try await args.session()
            try await session.refuseIfPaused()
            let tree = try await session.accessibilityTree(includeRemote: args.bool("include_web") ?? true)
            let screen = try await session.display().bounds
            let limit = min(max(1, args.int("max_elements") ?? defaultElementLimit), maxElementLimit)
            func capped(_ lines: [String]) -> String {
                guard lines.count > limit else { return lines.joined(separator: "\n") }
                return (lines.prefix(limit) + ["… \(lines.count - limit) more element(s) not shown; pass max_elements (up to \(maxElementLimit)) to see them."])
                    .joined(separator: "\n")
            }
            switch args.string("format") ?? "compact" {
            case "compact":
                // Apps can report one element several times (the keyboard's
                // keys, three times over); a repeat says nothing new.
                var shown = Set<String>()
                let lines = tree.meaningfulElements.map { $0.summary(on: screen) }.filter { shown.insert($0).inserted }
                return [.plain(capped(lines))]
            case "all":
                var lines: [String] = []
                func visit(_ element: AXElement, depth: Int) {
                    var node = element
                    node.children = nil
                    lines.append(String(repeating: "  ", count: depth) + node.summary(on: screen))
                    element.children?.forEach { visit($0, depth: depth + 1) }
                }
                visit(tree, depth: 0)
                return [.plain(capped(lines))]
            case "json":
                return [.plain(try JSONOutput.encode(tree))]
            default:
                throw ToolError("format must be compact, all or json.")
            }
        }
    )

    static let describePoint = ToolEntry(
        tool: Tool(
            name: "describe_point",
            description: "Describe the accessibility element at a point. \(coordinateContract)",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "x": Schema.number("X in points."),
                "y": Schema.number("Y in points."),
            ], required: ["x", "y"])
        ),
        handler: { args in
            let session = try await args.session()
            try await session.refuseIfPaused()
            guard let point = args.point() else { throw ToolError("x and y are required.") }
            return [.plain(try await session.element(at: point).summary)]
        }
    )

    static let findElements = ToolEntry(
        tool: Tool(
            name: "find_elements",
            description: "List the elements matching a query (every given field must match), numbered for the index argument of tap, type_text and the like. \(coordinateContract)",
            inputSchema: Schema.object(Schema.merge(["udid": Schema.udid], Schema.query))
        ),
        handler: { args in
            let session = try await args.session()
            try await session.refuseIfPaused()
            let query = args.query
            guard !query.isEmpty else { throw ToolError("Pass at least one of label, label_contains, identifier, role, value, value_contains, text_match.") }
            let matches = try await session.findElements(query)
            guard !matches.isEmpty else { return [.plain("No elements match \(query.description).")] }
            let screen = try await session.display().bounds
            return [.plain(matches.enumerated().map { "[\($0.offset)] \($0.element.summary(on: screen))" }.joined(separator: "\n"))]
        }
    )

    static let waitFor = ToolEntry(
        tool: Tool(
            name: "wait_for",
            description: "Wait until an element matching the query appears (or, with gone, disappears), then for the screen to settle. Re-checks whenever the screen changes. The tool for content that loads. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.query, [
                "screenshot": Schema.settle["screenshot"]!,
                "udid": Schema.udid,
                "gone": Schema.boolean("Wait for the element to disappear instead (default false)."),
                "timeout_ms": Schema.number("Fail after this long (default 10000)."),
            ]))
        ),
        handler: { args in
            let session = try await args.session()
            try await session.refuseIfPaused()
            let query = args.query
            guard !query.isEmpty else { throw ToolError("Pass at least one element query field, e.g. label.") }
            let gone = args.bool("gone") ?? false
            let (element, elapsed) = try await session.waitFor(query, gone: gone, timeout: args.milliseconds("timeout_ms") ?? .seconds(10))
            let ms = elapsed.inMilliseconds
            if gone { return await args.result("\(query.description) is gone after \(ms) ms.", session: session) }
            return await args.result("Found \(element?.summary ?? query.description) after \(ms) ms.", session: session)
        }
    )
}
