// ONC RPC v2 (RFC 5531) message layer: decode calls, encode replies.

public enum RPCAuth: Sendable, Equatable {
    case none
    case sys(uid: UInt32, gid: UInt32)
    case other(flavor: UInt32)
}

public struct RPCCall: Sendable {
    public let xid: UInt32
    public let program: UInt32
    public let version: UInt32
    public let procedure: UInt32
    public let auth: RPCAuth
    /// Positioned at the first byte of the procedure arguments.
    public var args: XDRReader
}

public enum RPCReply: Sendable {
    case success(XDRWriter)
    case programUnavailable
    case programMismatch(low: UInt32, high: UInt32)
    case procedureUnavailable
    case garbageArguments
    case systemError
    /// Call rejected for its credentials (auth_stat value).
    case authError(UInt32)
}

/// One RPC program (for example NFS or MOUNT) served by `RPCServer`.
public protocol RPCProgram: Sendable {
    var program: UInt32 { get }
    var versions: ClosedRange<UInt32> { get }
    func handle(_ call: RPCCall) async -> RPCReply
}

enum RPCMessage {
    static let call: UInt32 = 0
    static let reply: UInt32 = 1
    static let authNone: UInt32 = 0
    static let authSys: UInt32 = 1
    static let authBadCred: UInt32 = 1
    static let authTooWeak: UInt32 = 5

    /// Maximum credential/verifier body length (RFC 5531 caps it at 400).
    static let maxAuthBody = 400

    enum DecodeError: Error {
        case notACall(xid: UInt32)
        case rpcVersionMismatch(xid: UInt32)
    }

    static func decodeCall(_ record: [UInt8]) throws -> RPCCall {
        var r = XDRReader(record)
        let xid = try r.u32()
        guard try r.u32() == call else { throw DecodeError.notACall(xid: xid) }
        guard try r.u32() == 2 else { throw DecodeError.rpcVersionMismatch(xid: xid) }
        let program = try r.u32()
        let version = try r.u32()
        let procedure = try r.u32()

        let credFlavor = try r.u32()
        let credBody = try r.opaque(max: maxAuthBody)
        _ = try r.u32()  // verifier flavor
        _ = try r.opaque(max: maxAuthBody)

        let auth: RPCAuth
        switch credFlavor {
        case authNone: auth = .none
        case authSys: auth = try decodeAuthSys(credBody)
        default: auth = .other(flavor: credFlavor)
        }
        return RPCCall(xid: xid, program: program, version: version,
                       procedure: procedure, auth: auth, args: r)
    }

    private static func decodeAuthSys(_ body: [UInt8]) throws -> RPCAuth {
        var r = XDRReader(body)
        _ = try r.u32()  // stamp
        _ = try r.string(max: 255)  // machine name
        let uid = try r.u32()
        let gid = try r.u32()
        return .sys(uid: uid, gid: gid)
    }

    static func encodeReply(xid: UInt32, _ reply: RPCReply) -> XDRWriter {
        var w = XDRWriter()
        w.u32(xid)
        w.u32(RPCMessage.reply)
        if case .authError(let stat) = reply {
            w.u32(1)  // MSG_DENIED
            w.u32(1)  // AUTH_ERROR
            w.u32(stat)
            return w
        }
        w.u32(0)  // MSG_ACCEPTED
        w.u32(authNone)  // verifier: AUTH_NONE, empty body
        w.u32(0)
        switch reply {
        case .success(let body):
            w.u32(0)
            w.append(body)
        case .programUnavailable: w.u32(1)
        case .programMismatch(let low, let high):
            w.u32(2)
            w.u32(low)
            w.u32(high)
        case .procedureUnavailable: w.u32(3)
        case .garbageArguments: w.u32(4)
        case .systemError: w.u32(5)
        case .authError: preconditionFailure("handled above")
        }
        return w
    }

    static func encodeRPCMismatch(xid: UInt32) -> XDRWriter {
        var w = XDRWriter()
        w.u32(xid)
        w.u32(RPCMessage.reply)
        w.u32(1)  // MSG_DENIED
        w.u32(0)  // RPC_MISMATCH
        w.u32(2)
        w.u32(2)
        return w
    }
}
