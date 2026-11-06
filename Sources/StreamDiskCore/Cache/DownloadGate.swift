/// Limits concurrent downloads and hands free slots to the most urgent waiter.
///
/// Downloads sharing a link split its bandwidth, so starting everything at once makes the
/// chunk a player is blocked on finish last. Capping concurrency and ordering by priority
/// keeps the blocking chunk on the wire first.
actor DownloadGate {
    /// Lower sorts first: (urgency class, position in file).
    struct Priority: Comparable, Sendable {
        var urgent: Bool
        var index: UInt64

        static func < (a: Priority, b: Priority) -> Bool {
            if a.urgent != b.urgent { return a.urgent }
            return a.index < b.index
        }
    }

    private struct Waiter {
        let id: Int
        let group: String
        var priority: Priority
        let continuation: CheckedContinuation<Bool, Never>
    }

    let limit: Int
    /// Slots only urgent requests may use, so a blocked read never waits behind readahead.
    let reserved: Int
    private var running = 0
    private var urgentRunning = 0
    /// Urgency each running request started with, since a queued request can be promoted.
    private var started: [Int: Bool] = [:]
    private var waiting: [Int: Waiter] = [:]

    init(limit: Int, reserved: Int = 1) {
        precondition(limit > reserved && reserved >= 0)
        self.limit = limit
        self.reserved = reserved
    }

    /// Waits for a slot. Returns false if the request was dropped while queued.
    func acquire(id: Int, group: String, priority: Priority) async -> Bool {
        if canStart(priority) {
            start(id, priority)
            return true
        }
        return await withCheckedContinuation { cont in
            waiting[id] = Waiter(id: id, group: group, priority: priority, continuation: cont)
        }
    }

    func release(id: Int) {
        guard let urgent = started.removeValue(forKey: id) else { return }
        running -= 1
        if urgent { urgentRunning -= 1 }
        startWaiters()
    }

    /// Readahead also waits while anything urgent is downloading: on a slow link, sharing it
    /// would delay the bytes a player is blocked on.
    private func canStart(_ p: Priority) -> Bool {
        p.urgent ? running < limit : urgentRunning == 0 && running < limit - reserved
    }

    private func start(_ id: Int, _ p: Priority) {
        running += 1
        if p.urgent { urgentRunning += 1 }
        started[id] = p.urgent
    }

    private func startWaiters() {
        while let next = waiting.values.min(by: { $0.priority < $1.priority }), canStart(next.priority) {
            waiting[next.id] = nil
            start(next.id, next.priority)
            next.continuation.resume(returning: true)
        }
    }

    /// Raises a queued request, for example when a reader starts waiting on a prefetch.
    func promote(id: Int, to priority: Priority) {
        guard var w = waiting[id], priority < w.priority else { return }
        w.priority = priority
        waiting[id] = w
        startWaiters()
    }

    /// Drops queued, non-urgent requests of a group that `keep` rejects.
    func drop(group: String, keep: (UInt64) -> Bool) {
        for (id, w) in waiting where w.group == group && !w.priority.urgent && !keep(w.priority.index) {
            waiting[id] = nil
            w.continuation.resume(returning: false)
        }
    }

    var queuedCount: Int { waiting.count }
}
