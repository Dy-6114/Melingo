import Foundation

/// Serializes LLM / remote AI work so Reader batch, Study, and Ask do not race.
public actor LLMRequestQueue {
    public enum Priority: Int, Sendable, Comparable {
        case batch = 0
        case analytical = 1
        case interactive = 2

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public static let shared = LLMRequestQueue()

    private var running = 0
    private var maxConcurrent = 1
    private var waiters: [Waiter] = []

    private struct Waiter {
        let priority: Priority
        let continuation: CheckedContinuation<Void, Never>
    }

    public init() {}

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, value)
        drain()
    }

    public func enqueue<T: Sendable>(
        priority: Priority,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(priority: priority)
        defer { release() }
        return try await operation()
    }

    private func acquire(priority: Priority) async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(priority: priority, continuation: cont))
            waiters.sort { $0.priority > $1.priority }
        }
    }

    private func release() {
        running = max(0, running - 1)
        drain()
    }

    private func drain() {
        while running < maxConcurrent, !waiters.isEmpty {
            running += 1
            let next = waiters.removeFirst()
            next.continuation.resume()
        }
    }
}
