/// MOUNT version 3 (RFC 1813 appendix I). Exports a single path, "/", mapped to the backend root.
public struct MountProgram: RPCProgram {
    public let program: UInt32 = 100005
    public let versions: ClosedRange<UInt32> = 3...3

    let rootID: UInt64

    public init(rootID: UInt64) {
        self.rootID = rootID
    }

    public func handle(_ call: RPCCall) async -> RPCReply {
        var args = call.args
        var w = XDRWriter()
        switch call.procedure {
        case 0, 3, 4:  // NULL, UMNT, UMNTALL: no state to keep
            if call.procedure == 3 { _ = try? args.string(max: 1024) }
        case 1:  // MNT
            guard let path = try? args.string(max: 1024) else { return .garbageArguments }
            guard path == "/" || path.isEmpty else {
                w.u32(NFSStatus.noent.rawValue)
                break
            }
            w.u32(0)
            w.opaque(FileHandle.encode(rootID))
            w.u32(2)  // auth flavors accepted
            w.u32(RPCMessage.authSys)
            w.u32(RPCMessage.authNone)
        case 2:  // DUMP: empty mount list
            w.bool(false)
        case 5:  // EXPORT
            w.bool(true)
            w.string("/")
            w.bool(false)  // no group restrictions
            w.bool(false)
        default:
            return .procedureUnavailable
        }
        return .success(w)
    }
}
