import Foundation
import os

/// Decides when written files upload.
///
/// NFS has no "close", so a file counts as finished once it has had no writes for `quiet`.
/// A write during an upload cancels it; the upload starts over once writes stop again.
/// Failed uploads retry with exponential backoff.
actor UploadQueue {
    typealias Perform = @Sendable (UInt64) async throws -> Void

    let quiet: Duration
    let limit: Int
    private var perform: Perform?
    private var timers: [UInt64: Task<Void, Never>] = [:]
    private var ready: [UInt64] = []
    private var running: [UInt64: (token: Int, task: Task<Void, Never>)] = [:]
    private var failures: [UInt64: Int] = [:]
    private var nextToken = 0
    private let log = Logger(subsystem: "app.streamdisk", category: "upload")

    init(quiet: Duration = .seconds(2), limit: Int = 2) {
        self.quiet = quiet
        self.limit = limit
    }

    func start(_ perform: @escaping Perform) {
        self.perform = perform
        pump()
    }

    /// The file changed: restart its quiet period, cancelling any upload in progress.
    func touch(_ id: UInt64) {
        stopRunning(id)
        ready.removeAll { $0 == id }
        failures[id] = nil
        schedule(id, after: quiet)
    }

    /// The file no longer needs uploading (deleted, or became local-only).
    func cancel(_ id: UInt64) {
        timers.removeValue(forKey: id)?.cancel()
        stopRunning(id)
        ready.removeAll { $0 == id }
        failures[id] = nil
    }

    /// Queue without waiting, for uploads recovered after a restart.
    func enqueue(_ id: UInt64) {
        guard running[id] == nil, !ready.contains(id) else { return }
        ready.append(id)
        pump()
    }

    var pendingCount: Int { Set(timers.keys).union(ready).union(running.keys).count }

    private func schedule(_ id: UInt64, after delay: Duration) {
        timers.removeValue(forKey: id)?.cancel()
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.timerFired(id)
        }
    }

    private func timerFired(_ id: UInt64) {
        timers[id] = nil
        enqueue(id)
    }

    private func stopRunning(_ id: UInt64) {
        running.removeValue(forKey: id)?.task.cancel()
        pump()
    }

    private func pump() {
        guard let perform else { return }
        while running.count < limit, !ready.isEmpty {
            let id = ready.removeFirst()
            nextToken += 1
            let token = nextToken
            let task = Task { [weak self] in
                do {
                    try await perform(id)
                    await self?.finished(id, token: token, error: nil)
                } catch {
                    await self?.finished(id, token: token, error: error)
                }
            }
            running[id] = (token, task)
        }
    }

    private func finished(_ id: UInt64, token: Int, error: Error?) {
        // A newer run (after a touch) owns the entry; this one was cancelled.
        guard running[id]?.token == token else { return }
        running[id] = nil
        if let error, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
            let n = (failures[id] ?? 0) + 1
            failures[id] = n
            let wait = min(300.0, 5 * pow(2.0, Double(n - 1)))
            log.error("upload \(id) failed (attempt \(n)), retrying in \(Int(wait)) s: \(String(describing: error), privacy: .public)")
            schedule(id, after: .seconds(wait))
        } else {
            failures[id] = nil
        }
        pump()
    }
}
