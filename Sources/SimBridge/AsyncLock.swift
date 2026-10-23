/// A lock for async code. Tasks get it in the order they asked, and a task
/// that holds it can take it again, so nested callers do not deadlock.
actor AsyncLock {
    private var locked = false
    /// Tasks waiting for the lock, handed it one at a time.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The locks the current task holds.
    @TaskLocal private static var held: Set<ObjectIdentifier> = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let id = ObjectIdentifier(self)
        if Self.held.contains(id) { return try await body() }
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
        defer {
            if waiters.isEmpty {
                locked = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await Self.$held.withValue(Self.held.union([id])) {
            try await body()
        }
    }
}
