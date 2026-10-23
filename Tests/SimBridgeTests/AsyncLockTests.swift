import Foundation
import Testing
@testable import SimBridge

@Suite struct AsyncLockTests {
    /// Records which bodies are inside the lock.
    actor Log {
        var inside = 0
        var mostInside = 0
        var order: [Int] = []
        func enter(_ id: Int) { inside += 1; mostInside = max(mostInside, inside); order.append(id) }
        func leave() { inside -= 1 }
    }

    @Test func bodiesRunOneAtATimeInArrivalOrder() async throws {
        let lock = AsyncLock()
        let log = Log()
        // The first body holds the lock while the others queue up behind it.
        let first = Task {
            try await lock.run {
                await log.enter(0)
                try await Task.sleep(for: .milliseconds(100))
                await log.leave()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        var others: [Task<Void, any Error>] = []
        for id in 1...3 {
            others.append(Task {
                try await lock.run {
                    await log.enter(id)
                    try await Task.sleep(for: .milliseconds(5))
                    await log.leave()
                }
            })
            try await Task.sleep(for: .milliseconds(10))
        }
        try await first.value
        for task in others { try await task.value }
        #expect(await log.mostInside == 1)
        #expect(await log.order == [0, 1, 2, 3])
    }

    @Test func aTaskCanTakeALockItHolds() async throws {
        let lock = AsyncLock()
        let value = try await lock.run { try await lock.run { 42 } }
        #expect(value == 42)
    }

    @Test func aThrowingBodyReleasesTheLock() async throws {
        let lock = AsyncLock()
        await #expect(throws: CancellationError.self) {
            try await lock.run { throw CancellationError() }
        }
        #expect(try await lock.run { true })
    }
}
