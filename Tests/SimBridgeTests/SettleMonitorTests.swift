import Testing
@testable import SimBridge

@Suite struct SettleMonitorTests {
    let columns = 20
    let rows = 30

    func grid(changing cells: [(row: Int, column: Int)]) -> ([UInt8], [UInt8]) {
        let old = [UInt8](repeating: 200, count: columns * rows)
        var new = old
        for cell in cells { new[cell.row * columns + cell.column] = 40 }
        return (old, new)
    }

    @Test func identicalFramesAreNotActivity() {
        let (old, _) = grid(changing: [])
        #expect(!SettleMonitor.isSignificantChange(from: old, to: old, columns: columns))
    }

    @Test func tinyLuminanceNoiseIsIgnored() {
        let old = [UInt8](repeating: 200, count: columns * rows)
        let new = old.map { $0 - 3 }
        #expect(!SettleMonitor.isSignificantChange(from: old, to: new, columns: columns))
    }

    @Test func blinkingCaretIsIgnored() {
        // One column wide, three cells tall: a text cursor.
        let (old, new) = grid(changing: [(10, 5), (11, 5), (12, 5)])
        #expect(!SettleMonitor.isSignificantChange(from: old, to: new, columns: columns))
    }

    @Test func wideChangeIsActivity() {
        let (old, new) = grid(changing: [(10, 2), (10, 9)])
        #expect(SettleMonitor.isSignificantChange(from: old, to: new, columns: columns))
    }

    @Test func tallChangeIsActivity() {
        let (old, new) = grid(changing: [(2, 4), (20, 4)])
        #expect(SettleMonitor.isSignificantChange(from: old, to: new, columns: columns))
    }
}
