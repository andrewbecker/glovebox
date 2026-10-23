import Foundation
import MCP
import SimBridge

/// Hardware keyboard input (Indigo HID usage page 0x07). Works in any focused
/// text field without the on-screen keyboard. The screen settles once after the
/// whole key sequence, not after each keystroke.
enum KeyboardTools {
    static var all: [ToolEntry] {
        [typeText, pressKey, keyChord, holdKey, clearText]
    }

    static let keyNames = "Key names: return, escape, backspace, delete_forward, tab, space, left, right, up, down, home, end, page_up, page_down, f1-f12, a single character, or a hex HID usage like 0x2a."

    static func usage(_ name: String) throws -> UInt32 {
        guard let usage = Keyboard.usage(named: name) else {
            throw ToolError("Unknown key '\(name)'. \(keyNames)")
        }
        return usage
    }

    static func modifier(_ name: String) throws -> UInt32 {
        guard let usage = Keyboard.modifiers[name.lowercased()] else {
            throw ToolError("Unknown modifier '\(name)'. Use cmd, shift, option or ctrl (left_/right_ variants allowed).")
        }
        return usage
    }

    /// Taps the element the query selects so it takes focus, if a query was given.
    static func focus(_ args: Arguments, session: DeviceSession) async throws -> String {
        let query = args.query
        guard !query.isEmpty else { return "" }
        let element = try await session.resolve(query, stable: args.requiresStableTarget)
        _ = try await session.settled(SettleOptions()) { try await session.tap(at: element.tapPoint) }
        return " into \(element.summary)"
    }

    static let typeText = ToolEntry(
        tool: Tool(
            name: "type_text",
            description: "Type text into the focused field with the hardware keyboard. \\n and \\t type Return and Tab. Lines with characters outside the US keyboard layout (accents, emoji) are pasted instead. Pass an element query to tap a field first. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.query, Schema.index, Schema.settle, [
                "udid": Schema.udid,
                "text": Schema.string("Text to type."),
                "submit": Schema.boolean("Press Return after typing (default false)."),
            ]), required: ["text"])
        ),
        handler: { args in
            let raw = Keyboard.unescape(try args.require("text"))
            let text = args.bool("submit") == true ? raw + "\n" : raw
            return try await args.interaction { session in
                let target = try await focus(args, session: session)
                let (_, settle) = try await session.settled(try args.settleOptions()) {
                    try await session.type(text)
                }
                return await args.result("Typed \(text.count) character(s)\(target).\(settle.note)", session: session)
            }
        }
    )

    static let pressKey = ToolEntry(
        tool: Tool(
            name: "press_key",
            description: "Press a key, optionally several times and with modifiers. E.g. {\"key\":\"backspace\",\"repeat\":5} deletes five characters. \(keyNames) \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "key": Schema.string("Key name."),
                "repeat": Schema.integer("Number of presses (default 1, at most 1000)."),
                "modifiers": ["type": "array", "items": ["type": "string"], "description": "Modifiers to hold: cmd, shift, option, ctrl."],
            ]), required: ["key"])
        ),
        handler: { args in
            let name = try args.require("key")
            let key = try usage(name)
            let modifiers = try (args.values["modifiers"]?.arrayValue ?? []).compactMap(\.stringValue).map(modifier)
            let count = min(max(1, args.int("repeat") ?? 1), 1000)
            let session = try await args.session()
            try await session.refuseIfPaused()
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await session.press(key, modifiers: modifiers, times: count)
            }
            return await args.result("Pressed \(name)\(count > 1 ? " \(count) times" : "").\(settle.note)", session: session)
        }
    )

    static let keyChord = ToolEntry(
        tool: Tool(
            name: "key_chord",
            description: "Press keys together: each goes down in order, then all are released in reverse. E.g. [\"cmd\",\"a\"] selects all, [\"cmd\",\"shift\",\"h\"] goes home, [\"option\",\"backspace\"] deletes a word, [\"cmd\",\"k\"] toggles the software keyboard. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "keys": ["type": "array", "items": ["type": "string"], "description": "Modifier and key names, e.g. [\"cmd\", \"c\"]."],
            ]), required: ["keys"])
        ),
        handler: { args in
            let names = (args.values["keys"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !names.isEmpty else { throw ToolError("keys must be a non-empty array, e.g. [\"cmd\", \"a\"].") }
            let usages = try names.map(usage)
            let session = try await args.session()
            try await session.refuseIfPaused()
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await session.chord(usages)
            }
            return await args.result("Pressed \(names.joined(separator: "+")).\(settle.note)", session: session)
        }
    )

    static let holdKey = ToolEntry(
        tool: Tool(
            name: "hold_key",
            description: "Hold a key down for a duration, then release it. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "key": Schema.string("Key name."),
                "duration_ms": Schema.number("How long to hold the key."),
            ]), required: ["key", "duration_ms"])
        ),
        handler: { args in
            let name = try args.require("key")
            let key = try usage(name)
            guard let hold = args.milliseconds("duration_ms") else { throw ToolError("duration_ms is required.") }
            let session = try await args.session()
            try await session.refuseIfPaused()
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await session.press(key, hold: hold)
            }
            return await args.result("Held \(name).\(settle.note)", session: session)
        }
    )

    static let clearText = ToolEntry(
        tool: Tool(
            name: "clear_text",
            description: "Clear the focused text field (Cmd-A, then Backspace). Pass an element query to tap the field first. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.query, Schema.index, Schema.settle, ["udid": Schema.udid]))
        ),
        handler: { args in
            try await args.interaction { session in
                let target = try await focus(args, session: session)
                let (_, settle) = try await session.settled(try args.settleOptions()) {
                    try await session.press(Keyboard.usage(named: "a")!, modifiers: [Keyboard.leftCommand])
                    try await session.press(Keyboard.usage(named: "backspace")!)
                }
                return await args.result("Cleared text\(target).\(settle.note)", session: session)
            }
        }
    )
}
