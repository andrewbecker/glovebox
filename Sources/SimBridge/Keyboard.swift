/// USB HID keyboard usages (page 0x07) for the US layout, ported from idb's
/// FBSimulatorHIDEvent key tables (MIT License, Copyright (c) Meta Platforms,
/// Inc. and affiliates).
public enum Keyboard {
    public struct Stroke: Equatable, Sendable {
        public let usage: UInt32
        public let shift: Bool
    }

    /// A part of some text: keys to press, or text to paste.
    public enum Segment: Equatable, Sendable {
        case keys([Stroke])
        case paste(String)
    }

    /// Arrow keys pressed 10 ms apart were dropped by the guest; 100 ms apart
    /// they all landed (2026-10).
    static let arrowGap: Duration = .milliseconds(100)
    /// Between other keys: characters and deletes land at this spacing.
    static let keyGap: Duration = .milliseconds(10)

    /// How long to wait after pressing `usage` before the next key.
    public static func gap(after usage: UInt32) -> Duration {
        (0x4F...0x52).contains(usage) ? arrowGap : keyGap
    }

    public static let leftShift: UInt32 = 0xE1
    public static let leftCommand: UInt32 = 0xE3

    /// Modifier names accepted by `press_key` and `key_chord`.
    public static let modifiers: [String: UInt32] = [
        "cmd": 0xE3, "command": 0xE3, "left_cmd": 0xE3, "right_cmd": 0xE7,
        "shift": 0xE1, "left_shift": 0xE1, "right_shift": 0xE5,
        "option": 0xE2, "alt": 0xE2, "left_option": 0xE2, "right_option": 0xE6,
        "ctrl": 0xE0, "control": 0xE0, "left_ctrl": 0xE0, "right_ctrl": 0xE4,
    ]

    /// Non-character keys by name.
    public static let namedKeys: [String: UInt32] = {
        var keys: [String: UInt32] = [
            "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29,
            "backspace": 0x2A, "delete": 0x2A, "tab": 0x2B, "space": 0x2C,
            "caps_lock": 0x39, "insert": 0x49, "home": 0x4A, "page_up": 0x4B,
            "delete_forward": 0x4C, "end": 0x4D, "page_down": 0x4E,
            "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        ]
        for n in 1...12 { keys["f\(n)"] = 0x3A + UInt32(n - 1) }
        return keys
    }()

    /// Unshifted characters on a US keyboard.
    private static let plain: [Character: UInt32] = {
        var map: [Character: UInt32] = [
            "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22,
            "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
            "\n": 0x28, "\t": 0x2B, " ": 0x2C,
            "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31,
            ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
        ]
        for (offset, scalar) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[scalar] = 0x04 + UInt32(offset)
        }
        return map
    }()

    /// Characters typed with Shift held.
    private static let shifted: [Character: UInt32] = {
        var map: [Character: UInt32] = [
            "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22,
            "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
            "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31,
            ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
        ]
        for (offset, scalar) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map[scalar] = 0x04 + UInt32(offset)
        }
        return map
    }()

    public static func stroke(for character: Character) -> Stroke? {
        if let usage = plain[character] { return Stroke(usage: usage, shift: false) }
        if let usage = shifted[character] { return Stroke(usage: usage, shift: true) }
        if character == "\r\n" { return Stroke(usage: 0x28, shift: false) }
        return nil
    }

    /// Keystrokes for `text`, or nil if any character has no key on the US
    /// layout (accents, emoji, other scripts).
    public static func strokes(for text: String) -> [Stroke]? {
        var strokes: [Stroke] = []
        for character in text {
            guard let stroke = stroke(for: character) else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    /// Splits `text` at Returns and Tabs. A part with a character that has no
    /// key on the US layout is pasted whole; every other part, and every
    /// Return and Tab, is typed, so a newline still submits after pasted text.
    public static func segments(for text: String) -> [Segment] {
        var segments: [Segment] = []
        func append(_ strokes: [Stroke]) {
            if case .keys(let previous)? = segments.last {
                segments[segments.count - 1] = .keys(previous + strokes)
            } else {
                segments.append(.keys(strokes))
            }
        }
        var part = ""
        func flush() {
            guard !part.isEmpty else { return }
            if let strokes = strokes(for: part) { append(strokes) } else { segments.append(.paste(part)) }
            part = ""
        }
        for character in text {
            if character == "\n" || character == "\r\n" || character == "\t", let stroke = stroke(for: character) {
                flush()
                append([stroke])
            } else {
                part.append(character)
            }
        }
        flush()
        return segments
    }

    /// Resolves a key name ("backspace", "f5", "a", "7") or a hex usage
    /// ("0x2a") to a HID usage.
    public static func usage(named name: String) -> UInt32? {
        let lowered = name.lowercased()
        if let usage = namedKeys[lowered] ?? modifiers[lowered] { return usage }
        if lowered.hasPrefix("0x"), let usage = UInt32(lowered.dropFirst(2), radix: 16) { return usage }
        if lowered.count == 1, let stroke = stroke(for: Character(lowered)) { return stroke.usage }
        return nil
    }

    /// Expands `\n` and `\t` escape sequences that arrive literally in tool input.
    public static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }
}
