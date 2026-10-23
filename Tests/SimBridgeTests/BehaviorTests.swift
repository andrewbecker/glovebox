import CoreGraphics
import Foundation
import Testing
@testable import SimBridge

private func element(_ json: String) -> AXElement {
    try! JSONDecoder().decode(AXElement.self, from: Data(json.utf8))
}

@Suite struct PickTests {
    let list = element("""
        {"role":"Application","label":"Settings","frame":[0,0,402,874],"enabled":true,"children":[
          {"role":"Button","label":"General","frame":[16,200,370,52],"enabled":true,"children":[
            {"role":"StaticText","label":"General","frame":[60,214,80,22],"enabled":true}
          ]},
          {"role":"Button","label":"Wi-Fi","frame":[16,260,370,52],"enabled":true},
          {"role":"Button","label":"Wi-Fi","frame":[16,320,370,52],"enabled":true}
        ]}
        """).allElements

    @Test func aMatchInsideAnotherMatchCountsOnce() throws {
        #expect(try ElementQuery(label: "General").pick(from: list).role == "Button")
    }

    @Test func separateMatchesAreRefusedWithANumberedList() {
        do {
            _ = try ElementQuery(label: "Wi-Fi").pick(from: list)
            Issue.record("expected a refusal")
        } catch {
            let message = SimBridgeError.message(for: error)
            #expect(message.hasPrefix("2 elements match label=\"Wi-Fi\", so none was picked."))
            #expect(message.contains("[0] Button \"Wi-Fi\""))
            #expect(message.contains("[1] Button \"Wi-Fi\""))
        }
    }

    @Test func indexPicksAmongMatches() throws {
        #expect(try ElementQuery(label: "Wi-Fi", index: 1).pick(from: list).rect.minY == 320)
    }

    @Test func theApplicationRootIsNeverPickedByLabel() throws {
        #expect(throws: (any Error).self) { try ElementQuery(label: "Settings").pick(from: list) }
        #expect(try ElementQuery(label: "Settings", role: "Application").pick(from: list).role == "Application")
    }

    @Test func narrowSpacesMatchPlainSpaces() {
        // iOS writes times as "7:20\u{202F}AM".
        let clock = element(#"{"role":"StaticText","label":"7:20\#u{202F}AM","frame":[0,0,40,20],"enabled":true}"#)
        #expect(ElementQuery(label: "7:20 AM").matches(clock))
        #expect(ElementQuery.normalized("a\u{00A0}b\u{2007}c") == "a b c")
    }
}

@Suite struct HitTestGridTests {
    let screen = CGSize(width: 400, height: 800)

    @Test func anEmptyScreenIsProbedEvery50Points() {
        let root = element(#"{"role":"Application","frame":[0,0,400,800],"enabled":true}"#)
        let points = HitTestGrid.points(for: root, screen: screen)
        #expect(points.count == 8 * 16)
        #expect(points.allSatisfy { $0.x.truncatingRemainder(dividingBy: 50) == 25 })
    }

    @Test func pointsUnderWalkedElementsAreSkipped() {
        let root = element("""
            {"role":"Application","frame":[0,0,400,800],"enabled":true,"children":[
              {"role":"Button","label":"Back","frame":[0,0,400,400],"enabled":true}
            ]}
            """)
        let points = HitTestGrid.points(for: root, screen: screen)
        #expect(points.allSatisfy { $0.y > 400 })
        #expect(points.count == 8 * 8)
    }

    @Test func containersCoverNothingOfTheirOwn() {
        // The open iPhone Duo's Settings: a full-screen group holding the
        // detail rows, and a labelled sidebar whose rows the walk missed.
        let root = element("""
            {"role":"Application","frame":[0,0,400,800],"enabled":true,"children":[
              {"role":"Group","label":"Sidebar","identifier":"sidebar","frame":[0,0,200,800],"enabled":true},
              {"role":"Group","frame":[0,0,400,800],"enabled":true,"children":[
                {"role":"Button","label":"About","frame":[200,0,200,800],"enabled":true}
              ]}
            ]}
            """)
        let points = HitTestGrid.points(for: root, screen: screen)
        #expect(points.count == 4 * 16, "the sidebar's half is probed, the About row's is not")
        #expect(points.allSatisfy { $0.x < 200 })
    }

    @Test func emptyBarsAreProbedAlongTheirMiddle() {
        // A web view's bar: no children, no content of its own.
        let root = element("""
            {"role":"Application","frame":[0,0,400,800],"enabled":true,"children":[
              {"role":"Group","frame":[0,0,400,800],"enabled":true},
              {"role":"Group","frame":[0,700,400,100],"enabled":true}
            ]}
            """)
        let points = HitTestGrid.points(for: root, screen: screen)
        #expect(points.contains(CGPoint(x: 12.5, y: 750)))
        #expect(points.filter { $0.y == 750 }.count >= 16)
    }
}

@Suite struct InputPacingTests {
    @Test func hingeSweepsIn45EvenSteps() {
        let angles = DeviceSession.hingeSweep(from: 180, to: 0)
        #expect(angles.count == 45)
        #expect(angles.first == 176)
        #expect(angles.last == 0)
    }

    @Test func swipesMakeAtLeast20Moves() {
        #expect(DeviceSession.swipeMoveCount(duration: .milliseconds(200), interval: .milliseconds(8)) == 20)
        // Indigo's 16 ms limit leaves room for fewer.
        #expect(DeviceSession.swipeMoveCount(duration: .milliseconds(160), interval: .milliseconds(17)) == 9)
        #expect(DeviceSession.swipeMoveCount(duration: .seconds(1), interval: .milliseconds(8)) == 58)
    }

    @Test func arrowKeysAreSpacedFurtherApart() {
        #expect(Keyboard.gap(after: 0x50) == .milliseconds(100))
        #expect(Keyboard.gap(after: 0x04) == .milliseconds(10))
    }
}

@Suite struct ScrollPlanTests {
    let screen = CGSize(width: 400, height: 800)

    @Test func anElementClearOfTheBarsIsInView() {
        #expect(ScrollPlan.next(element: CGRect(x: 0, y: 300, width: 400, height: 50), screen: screen, direction: "up") == .done)
    }

    @Test func anElementUnderTheTabBarIsDraggedUp() {
        guard case .swipe(let from, let to) = ScrollPlan.next(element: CGRect(x: 0, y: 720, width: 400, height: 50),
                                                              screen: screen, direction: "down") else {
            Issue.record("expected a swipe")
            return
        }
        #expect(to.y < from.y, "the finger moves up to bring lower content into view, whatever direction says")
    }

    @Test func aMissingElementFollowsTheDirection() {
        guard case .swipe(let from, let to) = ScrollPlan.next(element: nil, screen: screen, direction: "up") else {
            Issue.record("expected a swipe")
            return
        }
        #expect(to.y < from.y)
    }

    @Test func movesUnderFourPointsAreStill() {
        let before = [element(#"{"role":"Button","label":"Row","frame":[0,100,400,50],"enabled":true}"#)]
        let bounced = [element(#"{"role":"Button","label":"Row","frame":[0,103,400,50],"enabled":true}"#)]
        let scrolled = [element(#"{"role":"Button","label":"Row","frame":[0,40,400,50],"enabled":true}"#)]
        #expect(!ScrollPlan.moved(before: before, after: bounced))
        #expect(ScrollPlan.moved(before: before, after: scrolled))
    }
}

@Suite struct DebuggerTests {
    @Test func breakpointSpecsSplitIntoFileAndLine() {
        #expect(Debugger.fileLine("TestApp.swift:35")! == ("TestApp.swift", 35))
        #expect(Debugger.fileLine("/a/b:c/File.swift:7")! == ("/a/b:c/File.swift", 7))
        #expect(Debugger.fileLine("MyView.save()") == nil)
        #expect(Debugger.fileLine(":3") == nil)
    }
}

@Suite struct HitPointTests {
    /// A widget's text, reported in the widget's own space.
    let widgetText = element("""
        {"role":"StaticText","label":" -- ","frame":[17.3,176.3,19.3,15.7],"enabled":true,"hitTested":true,"at":[300,440]}
        """)

    @Test func anElementWithAnUnreliableFrameIsTappedWhereItWasFound() {
        #expect(widgetText.tapPoint == CGPoint(x: 300, y: 440))
        #expect(widgetText.summary == #"StaticText " -- " at=(300,440)"#)
    }

    @Test func itsOnScreenTestUsesThatPoint() {
        let screen = CGRect(x: 0, y: 0, width: 951, height: 669)
        #expect(!widgetText.summary(on: screen).hasSuffix("off-screen"))
    }

    @Test func aCacheServesOnlyTheSameScreenAndTree() {
        let cache = HitTestCache(display: 3, screen: 0xABC, tree: 7, elements: [widgetText])
        #expect(cache.matches(display: 3, screen: 0xABC, tree: 7))
        #expect(!cache.matches(display: 3, screen: 0xABD, tree: 7))
        #expect(!cache.matches(display: 3, screen: 0xABC, tree: 8))
        #expect(!cache.matches(display: 1, screen: 0xABC, tree: 7))
    }
}
