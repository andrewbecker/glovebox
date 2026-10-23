import Testing
@testable import SimBridge

@Suite struct KeyboardTests {
    @Test func lettersDigitsAndPunctuation() throws {
        let strokes = try #require(Keyboard.strokes(for: "aZ0!\n"))
        #expect(strokes == [
            .init(usage: 0x04, shift: false),
            .init(usage: 0x1D, shift: true),
            .init(usage: 0x27, shift: false),
            .init(usage: 0x1E, shift: true),
            .init(usage: 0x28, shift: false),
        ])
    }

    @Test func everyPrintableASCIICharacterHasAKey() {
        for scalar in 0x20...0x7E {
            let character = Character(Unicode.Scalar(UInt8(scalar)))
            #expect(Keyboard.stroke(for: character) != nil, "no key for \(character)")
        }
    }

    @Test func textOutsideTheUSLayoutIsRejected() {
        #expect(Keyboard.strokes(for: "café") == nil)
        #expect(Keyboard.strokes(for: "👍") == nil)
    }

    @Test func textInTheUSLayoutIsTypedInOnePiece() {
        #expect(Keyboard.segments(for: "hi\tyou\n") == [.keys(Keyboard.strokes(for: "hi\tyou\n")!)])
    }

    @Test func linesOutsideTheUSLayoutArePastedButReturnIsStillPressed() {
        let returnKey = Keyboard.stroke(for: "\n")!
        #expect(Keyboard.segments(for: "café au lait\nok") == [
            .paste("café au lait"),
            .keys([returnKey] + Keyboard.strokes(for: "ok")!),
        ])
        #expect(Keyboard.segments(for: "👍\n") == [.paste("👍"), .keys([returnKey])])
        #expect(Keyboard.segments(for: "") == [])
    }

    @Test func keyNames() {
        #expect(Keyboard.usage(named: "backspace") == 0x2A)
        #expect(Keyboard.usage(named: "Return") == 0x28)
        #expect(Keyboard.usage(named: "f12") == 0x45)
        #expect(Keyboard.usage(named: "0x4c") == 0x4C)
        #expect(Keyboard.usage(named: "a") == 0x04)
        #expect(Keyboard.usage(named: "cmd") == 0xE3)
        #expect(Keyboard.usage(named: "nonsense") == nil)
    }

    @Test func unescapesLiteralNewlinesAndTabs() {
        #expect(Keyboard.unescape(#"a\nb\tc"#) == "a\nb\tc")
    }
}
