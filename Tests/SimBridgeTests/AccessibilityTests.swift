import CoreGraphics
import Foundation
import Testing
@testable import SimBridge

@Suite struct AccessibilityTests {
    /// Shape produced by SBAccessibility for Settings > General.
    let tree: AXElement = {
        let json = """
        {"role":"Application","label":"Settings","frame":[0,0,466,678],"enabled":true,"pid":42,"children":[
          {"role":"Group","frame":[0,0,466,678],"enabled":true,"children":[
            {"role":"Heading","label":"General","frame":[40,172,80,26.3],"enabled":true},
            {"role":"Button","label":"About","identifier":"com.apple.settings.general.about","frame":[20,338.7,362,52],"enabled":true},
            {"role":"Button","label":"Health Data","frame":[20,425.7,362,52],"enabled":false},
            {"role":"TextField","value":"hello","placeholder":"Search","frame":[12.5,613.4,377,33.3],"enabled":true},
            {"role":"CheckBox","label":"Bold Text","value":"0","identifier":"ENHANCE_TEXT_LEGIBILITY","frame":[40,112.3,322,28],"enabled":true}
          ]},
          {"role":"GenericElement","identifier":"BackButton","frame":[399,175,38,38],"enabled":true}
        ]}
        """
        return try! JSONDecoder().decode(AXElement.self, from: Data(json.utf8))
    }()

    @Test func flattensDepthFirstWithoutChildren() {
        let all = tree.allElements
        #expect(all.map(\.role) == ["Application", "Group", "Heading", "Button", "Button", "TextField", "CheckBox", "GenericElement"])
        #expect(all.allSatisfy { $0.children == nil })
        #expect(tree.pid == 42)
    }

    @Test func meaningfulElementsDropBareContainers() {
        #expect(!tree.meaningfulElements.contains { $0.role == "Group" })
        #expect(tree.meaningfulElements.contains { $0.identifier == "BackButton" })
    }

    @Test func summaryIsOneCompactLine() {
        let about = tree.allElements[3]
        #expect(about.summary == #"Button "About" id=com.apple.settings.general.about frame=(20,339,362,52)"#)
        #expect(tree.allElements[4].summary.hasSuffix("disabled"))
        #expect(about.center.x == 201)
        #expect(abs(about.center.y - 364.7) < 0.001)
    }

    @Test func queriesAreCaseInsensitive() {
        func matches(_ query: ElementQuery) -> [String] {
            tree.allElements.filter(query.matches).map { $0.label ?? $0.identifier ?? $0.role }
        }
        #expect(matches(ElementQuery(label: "about")) == ["About"])
        #expect(matches(ElementQuery(labelContains: "DATA")) == ["Health Data"])
        #expect(matches(ElementQuery(role: "AXButton")) == ["About", "Health Data"])
        #expect(matches(ElementQuery(identifier: "backbutton")) == ["BackButton"])
        #expect(matches(ElementQuery(text: "search")) == ["TextField"])
        #expect(matches(ElementQuery(labelContains: "a", role: "Button")) == ["About", "Health Data"])
        #expect(matches(ElementQuery(label: "Missing")).isEmpty)
    }

    @Test func switchAndToggleFindCheckBoxes() {
        func matches(_ query: ElementQuery) -> [String] {
            tree.allElements.filter(query.matches).compactMap(\.label)
        }
        #expect(matches(ElementQuery(role: "Switch")) == ["Bold Text"])
        #expect(matches(ElementQuery(role: "toggle", value: "0")) == ["Bold Text"])
        #expect(matches(ElementQuery(role: "CheckBox")) == ["Bold Text"])
    }

    @Test func emptyQueryIsDetected() {
        #expect(ElementQuery().isEmpty)
        #expect(ElementQuery(index: 1).isEmpty, "an index alone selects nothing")
        #expect(!ElementQuery(role: "Button").isEmpty)
    }

    @Test func tapsAtTheActivationPointWhenThereIsOne() throws {
        // A SwiftUI Toggle row: the frame spans the row, the switch is at the right.
        let json = #"{"role":"CheckBox","label":"Notifications","value":"0","frame":[20,134,362,52],"activation":[332.5,160],"enabled":true}"#
        let toggle = try JSONDecoder().decode(AXElement.self, from: Data(json.utf8))
        #expect(toggle.tapPoint == CGPoint(x: 332.5, y: 160))
        #expect(tree.allElements[3].tapPoint == tree.allElements[3].center)
    }

    @Test func noMatchSuggestsNearMatches() {
        let stepper = """
        {"role":"Group","frame":[0,0,466,678],"enabled":true,"children":[
          {"role":"Button","label":"Count: 0, Decrement","identifier":"Decrement","frame":[268,196,47,32],"enabled":false},
          {"role":"Button","label":"Count: 0, Increment","identifier":"Increment","frame":[315,196,47,32],"enabled":true}
        ]}
        """
        let elements = try! JSONDecoder().decode(AXElement.self, from: Data(stepper.utf8)).allElements
        let message = ElementQuery(label: "Increment").noMatchMessage(in: elements)
        #expect(message.contains(#"Similar: Button "Count: 0, Increment" id=Increment"#))
        #expect(!message.contains("Decrement"))
        #expect(ElementQuery(label: "Missing").noMatchMessage(in: elements)
            == #"No element matches label="Missing". Call describe_ui to see what is on screen."#)
        #expect(ElementQuery(label: "Increment", role: "StaticText").noMatchMessage(in: elements)
            .contains("Similar") == false, "other fields still apply")
    }
}
