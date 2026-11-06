import Foundation
@preconcurrency import Network
import os

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackReceiver: Sendable {
    struct Redirect: Sendable {
        let query: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "streamdisk.oauth.loopback")
    private let result = OSAllocatedUnfairLock<CheckedContinuation<Redirect, Error>?>(initialState: nil)
    private let page: String

    init(successPage: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        page = successPage
    }

    /// Starts listening and returns the redirect URI to register with the authorization request.
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                let fire: (Result<UInt16, Error>) -> Void = { r in
                    if once.withLock({ done in defer { done = true }; return !done }) { cont.resume(with: r) }
                }
                switch state {
                case .ready: fire(.success(listener.port?.rawValue ?? 0))
                case .failed(let e): fire(.failure(e))
                case .cancelled: fire(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [self] conn in handle(conn) }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Waits for the browser to hit the redirect URI.
    func redirect() async throws -> Redirect {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                result.withLock { $0 = cont }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ r: Result<Redirect, Error>) {
        let cont = result.withLock { c -> CheckedContinuation<Redirect, Error>? in
            defer { c = nil }
            return c
        }
        cont?.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // First line: "GET /?code=...&state=... HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init)
            guard let target, let comps = URLComponents(string: target), comps.path == "/" || comps.path.isEmpty,
                  let items = comps.queryItems, !items.isEmpty
            else {
                respond(conn, status: "404 Not Found", body: "")
                return
            }
            respond(conn, status: "200 OK", body: page)
            var query: [String: String] = [:]
            for item in items { query[item.name] = item.value ?? "" }
            finish(.success(Redirect(query: query)))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + Data(bytes), completion: .contentProcessed { _ in conn.cancel() })
    }
}
