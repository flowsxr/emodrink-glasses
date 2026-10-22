//
// ShowcaseClock.swift
//
// The showcase runner's only source of time. The real clock is Task.sleep;
// the test clock holds every sleeper until `advance(by:)` moves time past
// its deadline, so tests/showcase-runner plays a 45 s idle timer in
// microseconds and in a fixed order. Both throw CancellationError when the
// sleeping task is cancelled. Foundation only.
//

import Foundation

@MainActor
protocol ShowcaseClock: AnyObject {
    func sleep(_ seconds: TimeInterval) async throws
}

@MainActor
final class RealShowcaseClock: ShowcaseClock {
    func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Deterministic time for tests: `now` moves only through `advance(by:)`.
@MainActor
final class TestShowcaseClock: ShowcaseClock {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var now: TimeInterval = 0
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var pendingSleepers: Int { sleepers.count }

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        let deadline = now + max(0, seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            // Runs after the append above: the main actor is serial and the
            // append happens before this task first suspends.
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    /// Moves time forward, waking sleepers in deadline order (ties in the
    /// order they slept). Sleepers that a woken task adds are honoured too
    /// when their deadline falls inside the window.
    func advance(by seconds: TimeInterval) async {
        let target = now + seconds
        await Self.settle()
        while let next = sleepers.filter({ $0.deadline <= target + 1e-9 })
            .min(by: { ($0.deadline, $0.id) < ($1.deadline, $1.id) }) {
            sleepers.removeAll { $0.id == next.id }
            now = max(now, next.deadline)
            next.continuation.resume()
            await Self.settle()
        }
        now = target
        await Self.settle()
    }

    private func cancel(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }

    /// Lets main-actor work that the last wake-up enqueued run to its next await.
    static func settle() async {
        for _ in 0..<60 { await Task.yield() }
    }
}
