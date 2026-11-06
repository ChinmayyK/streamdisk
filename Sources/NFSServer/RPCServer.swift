import Foundation
@preconcurrency import Network
import os

/// ONC RPC over TCP with record marking (RFC 5531 §11), bound to loopback only.
///
/// Calls on one connection are handled concurrently and replied to as they finish;
/// the macOS NFS client matches replies by xid and pipelines READs for readahead.
public final class RPCServer: Sendable {
    public typealias Authorizer = @Sendable (RPCAuth) -> Bool

    /// Largest record accepted: a 1 MiB WRITE payload plus headers.
    static let maxRecordSize = (1 << 20) + 64 * 1024

    private let programs: [UInt32: any RPCProgram]
    private let authorize: Authorizer
    private let listener: NWListener
    private let queue = DispatchQueue(label: "streamdisk.rpc.listener")
    private let log = Logger(subsystem: "app.streamdisk", category: "rpc")

    /// - Parameter port: TCP port on 127.0.0.1; 0 picks a free port.
    public init(programs: [any RPCProgram], port: UInt16 = 0, authorize: @escaping Authorizer) throws {
        self.programs = Dictionary(uniqueKeysWithValues: programs.map { ($0.program, $0) })
        self.authorize = authorize
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        let log = self.log
        listener.newConnectionHandler = { [self] conn in
            let c = RPCConnection(conn: conn, server: self)
            c.start()
        }
        return try await withCheckedThrowingContinuation { cont in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                let resume: (Result<UInt16, Error>) -> Void = { result in
                    let first = once.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { cont.resume(with: result) }
                }
                switch state {
                case .ready:
                    resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    func dispatch(_ record: [UInt8]) async -> XDRWriter? {
        let call: RPCCall
        do {
            call = try RPCMessage.decodeCall(record)
        } catch RPCMessage.DecodeError.rpcVersionMismatch(let xid) {
            return RPCMessage.encodeRPCMismatch(xid: xid)
        } catch {
            // Not a well-formed call: there is no xid we can trust, so drop it.
            log.debug("dropping malformed record: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard authorize(call.auth) else {
            return RPCMessage.encodeReply(xid: call.xid, .authError(RPCMessage.authTooWeak))
        }
        guard let program = programs[call.program] else {
            return RPCMessage.encodeReply(xid: call.xid, .programUnavailable)
        }
        guard program.versions.contains(call.version) else {
            return RPCMessage.encodeReply(
                xid: call.xid,
                .programMismatch(low: program.versions.lowerBound, high: program.versions.upperBound))
        }
        let reply = await program.handle(call)
        return RPCMessage.encodeReply(xid: call.xid, reply)
    }
}

/// Splits a TCP byte stream into RPC records.
struct RecordAssembler {
    enum Failure: Error { case recordTooLarge(Int) }

    private var buffer: [UInt8] = []
    private var record: [UInt8] = []
    let maxRecordSize: Int

    init(maxRecordSize: Int) { self.maxRecordSize = maxRecordSize }

    /// Feeds bytes and returns every record completed by them.
    mutating func feed(_ bytes: some Sequence<UInt8>) throws -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var out: [[UInt8]] = []
        var start = 0
        while buffer.count - start >= 4 {
            let header = UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16
                | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])
            let last = header & 0x8000_0000 != 0
            let length = Int(header & 0x7FFF_FFFF)
            guard record.count + length <= maxRecordSize else {
                throw Failure.recordTooLarge(record.count + length)
            }
            guard buffer.count - start - 4 >= length else { break }
            record.append(contentsOf: buffer[(start + 4)..<(start + 4 + length)])
            start += 4 + length
            if last {
                out.append(record)
                record = []
            }
        }
        if start > 0 { buffer.removeFirst(start) }
        return out
    }

    /// Frames a reply as one last-fragment record.
    static func frame(_ body: [UInt8]) -> Data {
        var data = Data(capacity: body.count + 4)
        let header = UInt32(body.count) | 0x8000_0000
        withUnsafeBytes(of: header.bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: body)
        return data
    }
}

private final class RPCConnection: @unchecked Sendable {
    // `assembler` is only touched on `queue`.
    private let conn: NWConnection
    private let server: RPCServer
    private let queue = DispatchQueue(label: "streamdisk.rpc.connection")
    private var assembler = RecordAssembler(maxRecordSize: RPCServer.maxRecordSize)

    init(conn: NWConnection, server: RPCServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: conn.stateUpdateHandler = nil
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                do {
                    for record in try assembler.feed(data) {
                        Task { [self] in
                            if let reply = await server.dispatch(record) {
                                conn.send(content: RecordAssembler.frame(reply.bytes),
                                          completion: .contentProcessed { _ in })
                            }
                        }
                    }
                } catch {
                    conn.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            receive()
        }
    }
}
