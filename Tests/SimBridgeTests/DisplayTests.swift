import CoreGraphics
import Testing
@testable import SimBridge

@Suite struct DisplayTests {
    /// The open iPhone Duo's inner panel: a 669x951 portrait framebuffer
    /// showing a 951x669 landscape interface ("rot90").
    let duoInner = CGSize(width: 951, height: 669)

    @Test func unrotatedPointsScaleToTheFramebuffer() {
        let ratio = Display.ratio(for: CGPoint(x: 233, y: 169.5), interfaceSize: CGSize(width: 466, height: 678), rotation: 0)
        #expect(ratio == CGPoint(x: 0.5, y: 0.25))
    }

    /// Measured on 2026-10-18: Settings' About row, at (603.5, 329.7) in
    /// accessibility frames, was hit by a touch at framebuffer point (339, 348).
    @Test func rotation90PutsTheInterfaceTopOnTheFramebufferLeft() {
        let ratio = Display.ratio(for: CGPoint(x: 603.5, y: 329.7), interfaceSize: duoInner, rotation: 90)
        #expect(abs(ratio.x * 669 - 329.7) < 0.01)
        #expect(abs(ratio.y * 951 - 347.5) < 0.01)
        // The interface's top-left corner is the framebuffer's bottom-left.
        #expect(Display.ratio(for: .zero, interfaceSize: duoInner, rotation: 90) == CGPoint(x: 0, y: 1))
    }

    @Test(arguments: [0, 90, 180, 270])
    func everyRotationMapsTheCornersToCorners(rotation: Int) {
        let size = (rotation == 90 || rotation == 270) ? duoInner : CGSize(width: 669, height: 951)
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
                       CGPoint(x: size.width, y: size.height)]
        let mapped = Set(corners.map { Display.ratio(for: $0, interfaceSize: size, rotation: rotation) }.map { [$0.x, $0.y] })
        #expect(mapped == [[0, 0], [1, 0], [0, 1], [1, 1]])
        let center = Display.ratio(for: CGPoint(x: size.width / 2, y: size.height / 2), interfaceSize: size, rotation: rotation)
        #expect(center == CGPoint(x: 0.5, y: 0.5))
    }

    @Test(arguments: [0, 90, 180, 270])
    func interfacePointsSurviveARoundTrip(rotation: Int) {
        let size = (rotation == 90 || rotation == 270) ? duoInner : CGSize(width: 669, height: 951)
        for point in [CGPoint(x: 12, y: 34), CGPoint(x: 500, y: 80), CGPoint(x: size.width, y: size.height)] {
            let ratio = Display.ratio(for: point, interfaceSize: size, rotation: rotation)
            let back = Display.interfacePoint(forRatio: ratio, interfaceSize: size, rotation: rotation)
            #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
        }
    }

    @Test func springBoardsFramebufferFrameLandsOnTheIcon() {
        // SpringBoard reported the Settings icon at (52,417.3,86.7,68) in the
        // inner panel's framebuffer (669x951 points); it shows at about
        // (466,52) in the 951x669 interface.
        let framebuffer = CGSize(width: 669, height: 951)
        func convert(_ point: CGPoint) -> CGPoint {
            Display.interfacePoint(forRatio: CGPoint(x: point.x / framebuffer.width, y: point.y / framebuffer.height),
                                   interfaceSize: duoInner, rotation: 90)
        }
        let a = convert(CGPoint(x: 52, y: 417.3)), b = convert(CGPoint(x: 138.7, y: 485.3))
        #expect(abs(min(a.x, b.x) - 465.7) < 0.01 && abs(min(a.y, b.y) - 52) < 0.01)
        #expect(abs(abs(a.x - b.x) - 68) < 0.01 && abs(abs(a.y - b.y) - 86.7) < 0.01)
    }
}
