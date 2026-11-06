import Foundation

/// File handles are a 4-byte tag plus the backend's 64-bit node id.
enum FileHandle {
    static let tag: [UInt8] = Array("SDK1".utf8)
    static let maxSize = 64

    static func encode(_ id: UInt64) -> [UInt8] {
        var w = XDRWriter(capacity: 12)
        w.fixedOpaque(tag)
        w.u64(id)
        return w.bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> UInt64 {
        guard bytes.count == 12, Array(bytes[0..<4]) == tag else { throw NFSStatus.badHandle }
        var r = XDRReader(bytes, offset: 4)
        return try r.u64()
    }
}

/// NFS version 3 (RFC 1813) over a `FileSystemBackend`. Read-only: mutating procedures return ROFS.
public struct NFSProgram: RPCProgram {
    public let program: UInt32 = 100003
    public let versions: ClosedRange<UInt32> = 3...3

    /// Largest READ the server returns. The client picks its own size up to this.
    static let maxTransfer: UInt32 = 1 << 20
    static let fsid: UInt64 = 0x5354_4D44_534B_0001

    let backend: any FileSystemBackend
    let owner: (uid: UInt32, gid: UInt32)
    /// Changes when the server restarts, telling clients to resend unstable writes.
    let writeVerifier = UInt64.random(in: .min ... .max)

    public init(backend: any FileSystemBackend, uid: UInt32 = getuid(), gid: UInt32 = getgid()) {
        self.backend = backend
        self.owner = (uid, gid)
    }

    enum Procedure: UInt32 {
        case null = 0, getattr, setattr, lookup, access, readlink, read, write, create, mkdir,
             symlink, mknod, remove, rmdir, rename, link, readdir, readdirplus, fsstat, fsinfo,
             pathconf, commit
    }

    public func handle(_ call: RPCCall) async -> RPCReply {
        guard let procedure = Procedure(rawValue: call.procedure) else { return .procedureUnavailable }
        var args = call.args
        do {
            switch procedure {
            case .null: return .success(XDRWriter())
            case .getattr: return .success(try await getattr(&args))
            case .lookup: return .success(try await lookup(&args))
            case .access: return .success(try await access(&args))
            case .read: return .success(try await read(&args))
            case .readdir: return .success(try await readdir(&args, plus: false))
            case .readdirplus: return .success(try await readdir(&args, plus: true))
            case .fsstat: return .success(try await fsstat(&args))
            case .fsinfo: return .success(try await fsinfo(&args))
            case .pathconf: return .success(try await pathconf(&args))
            case .readlink: return .success(failure(.notSupported, postOpAttrs: 1))
            case .symlink, .mknod: return .success(failure(.notSupported, wcc: 1))
            case .link: return .success(failure(.notSupported, postOpAttrs: 1, wcc: 1))
            case .setattr, .write, .create, .mkdir, .remove, .rmdir, .commit, .rename:
                guard let writable = backend as? any WritableFileSystemBackend else {
                    return .success(failure(.rofs, wcc: procedure == .rename ? 2 : 1))
                }
                return .success(try await handleWrite(procedure, &args, writable))
            }
        } catch is XDRError {
            return .garbageArguments
        } catch {
            return .systemError
        }
    }

    // MARK: Procedures

    private func getattr(_ args: inout XDRReader) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        var w = XDRWriter()
        do {
            let attrs = try await backend.attributes(of: id)
            w.u32(NFSStatus.ok.rawValue)
            encode(attrs, into: &w)
        } catch {
            w.u32(status(error).rawValue)
        }
        return w
    }

    private func lookup(_ args: inout XDRReader) async throws -> XDRWriter {
        let dirID = try handleArgument(&args)
        let name = try args.string(max: 255)
        let dirAttrs = try? await backend.attributes(of: dirID)
        var w = XDRWriter()
        do {
            guard let dirAttrs else { throw NFSStatus.stale }
            guard dirAttrs.kind == .directory else { throw NFSStatus.notdir }
            let attrs = name == "." ? dirAttrs : try await backend.lookup(name, in: dirID)
            w.u32(NFSStatus.ok.rawValue)
            w.opaque(FileHandle.encode(attrs.id))
            postOp(attrs, into: &w)
            postOp(dirAttrs, into: &w)
        } catch {
            w.u32(status(error).rawValue)
            postOp(dirAttrs, into: &w)
        }
        return w
    }

    private func access(_ args: inout XDRReader) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        let requested = try args.u32()
        var w = XDRWriter()
        do {
            let attrs = try await backend.attributes(of: id)
            // READ, LOOKUP and EXECUTE always; MODIFY, EXTEND and DELETE only when writable.
            let write: UInt32 = backend is any WritableFileSystemBackend ? 0x04 | 0x08 | 0x10 : 0
            let allowed: UInt32 = (attrs.kind == .directory ? 0x01 | 0x02 | 0x20 : 0x01) | write
            w.u32(NFSStatus.ok.rawValue)
            postOp(attrs, into: &w)
            w.u32(requested & allowed)
        } catch {
            w.u32(status(error).rawValue)
            postOp(nil, into: &w)
        }
        return w
    }

    private func read(_ args: inout XDRReader) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        let offset = try args.u64()
        let count = min(try args.u32(), Self.maxTransfer)
        var w = XDRWriter()
        var attrs: FileAttributes?
        do {
            let a = try await backend.attributes(of: id)
            attrs = a
            guard a.kind == .file else { throw NFSStatus.isdir }
            let data: [UInt8] = offset >= a.size || count == 0
                ? [] : try await backend.read(id, offset: offset, count: Int(min(UInt64(count), a.size - offset)))
            w = XDRWriter(capacity: data.count + 128)
            w.u32(NFSStatus.ok.rawValue)
            postOp(a, into: &w)
            w.u32(UInt32(data.count))
            w.bool(offset + UInt64(data.count) >= a.size)
            w.opaque(data)
        } catch {
            w = XDRWriter()
            w.u32(status(error).rawValue)
            postOp(attrs, into: &w)
        }
        return w
    }

    private func readdir(_ args: inout XDRReader, plus: Bool) async throws -> XDRWriter {
        let dirID = try handleArgument(&args)
        let cookie = try args.u64()
        let verifier = try args.u64()
        let dirCount = Int(try args.u32())
        let maxCount = plus ? Int(try args.u32()) : dirCount
        var w = XDRWriter()
        var dirAttrs: FileAttributes?
        do {
            let attrs = try await backend.attributes(of: dirID)
            dirAttrs = attrs
            guard attrs.kind == .directory else { throw NFSStatus.notdir }
            let listing = try await backend.list(dirID)
            if cookie != 0 && verifier != 0 && verifier != listing.version { throw NFSStatus.badCookie }

            // "." and ".." first; their attributes and handles are left for the client to LOOKUP.
            let names: [(name: String, attrs: FileAttributes?, id: UInt64)] =
                [(".", nil, dirID), ("..", nil, dirID)] + listing.entries.map { ($0.name, $0.attributes, $0.attributes.id) }
            guard cookie <= UInt64(names.count) else { throw NFSStatus.badCookie }

            var body = XDRWriter()
            var used = 4 + 88 + 8 + 8  // status, dir attributes, verifier, list terminator and eof
            var dirUsed = 0
            var index = Int(cookie)
            while index < names.count {
                let entry = names[index]
                var e = XDRWriter()
                e.bool(true)
                e.u64(entry.id)
                e.string(entry.name)
                e.u64(UInt64(index + 1))
                let dirBytes = e.bytes.count
                if plus {
                    postOp(entry.attrs, into: &e)
                    if entry.attrs != nil {
                        e.bool(true)
                        e.opaque(FileHandle.encode(entry.id))
                    } else {
                        e.bool(false)
                    }
                }
                let fitsAny = index == Int(cookie)  // always return at least one entry
                if !fitsAny && (used + e.bytes.count > maxCount || dirUsed + dirBytes > dirCount) { break }
                used += e.bytes.count
                dirUsed += dirBytes
                body.append(e)
                index += 1
            }
            w = XDRWriter(capacity: used)
            w.u32(NFSStatus.ok.rawValue)
            postOp(attrs, into: &w)
            w.u64(listing.version)
            w.append(body)
            w.bool(false)
            w.bool(index >= names.count)
        } catch {
            w = XDRWriter()
            w.u32(status(error).rawValue)
            postOp(dirAttrs, into: &w)
        }
        return w
    }

    private func fsstat(_ args: inout XDRReader) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        var w = XDRWriter()
        do {
            let attrs = try await backend.attributes(of: id)
            let s = try await backend.statistics()
            w.u32(NFSStatus.ok.rawValue)
            postOp(attrs, into: &w)
            w.u64(s.totalBytes)
            w.u64(s.freeBytes)
            w.u64(s.freeBytes)
            w.u64(s.totalFiles)
            w.u64(s.freeFiles)
            w.u64(s.freeFiles)
            w.u32(0)  // invarsec: may change at any time
        } catch {
            w.u32(status(error).rawValue)
            postOp(nil, into: &w)
        }
        return w
    }

    private func fsinfo(_ args: inout XDRReader) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        var w = XDRWriter()
        do {
            let attrs = try await backend.attributes(of: id)
            w.u32(NFSStatus.ok.rawValue)
            postOp(attrs, into: &w)
            w.u32(Self.maxTransfer)  // rtmax
            w.u32(Self.maxTransfer)  // rtpref
            w.u32(4096)  // rtmult
            w.u32(Self.maxTransfer)  // wtmax
            w.u32(Self.maxTransfer)  // wtpref
            w.u32(4096)  // wtmult
            w.u32(64 * 1024)  // dtpref
            w.u64(UInt64(Int64.max))  // maxfilesize
            w.u32(0)  // time_delta: 1 ns
            w.u32(1)
            w.u32(0x08)  // FSF3_HOMOGENEOUS
        } catch {
            w.u32(status(error).rawValue)
            postOp(nil, into: &w)
        }
        return w
    }

    private func pathconf(_ args: inout XDRReader) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        var w = XDRWriter()
        do {
            let attrs = try await backend.attributes(of: id)
            w.u32(NFSStatus.ok.rawValue)
            postOp(attrs, into: &w)
            w.u32(1)  // linkmax
            w.u32(255)  // name_max
            w.bool(true)  // no_trunc
            w.bool(true)  // chown_restricted
            w.bool(false)  // case_insensitive
            w.bool(true)  // case_preserving
        } catch {
            w.u32(status(error).rawValue)
            postOp(nil, into: &w)
        }
        return w
    }

    // MARK: Encoding

    func handleArgument(_ args: inout XDRReader) throws -> UInt64 {
        let raw = try args.opaque(max: FileHandle.maxSize)
        // A malformed handle is a valid call with a bad handle, not garbage arguments.
        return (try? FileHandle.decode(raw)) ?? .max
    }

    func status(_ error: Error) -> NFSStatus {
        (error as? NFSStatus) ?? .io
    }

    /// Failure body for procedures whose error result is only empty attribute blocks.
    func failure(_ status: NFSStatus, postOpAttrs: Int = 0, wcc: Int = 0) -> XDRWriter {
        var w = XDRWriter()
        w.u32(status.rawValue)
        for _ in 0..<postOpAttrs { w.bool(false) }
        for _ in 0..<wcc {
            w.bool(false)  // pre_op_attr
            w.bool(false)  // post_op_attr
        }
        return w
    }

    func postOp(_ attrs: FileAttributes?, into w: inout XDRWriter) {
        guard let attrs else {
            w.bool(false)
            return
        }
        w.bool(true)
        encode(attrs, into: &w)
    }

    /// fattr3: 84 bytes.
    func encode(_ a: FileAttributes, into w: inout XDRWriter) {
        let isDir = a.kind == .directory
        w.u32(isDir ? 2 : 1)  // NF3DIR / NF3REG
        w.u32(UInt32(a.permissions))
        w.u32(isDir ? 2 : 1)  // nlink
        w.u32(owner.uid)
        w.u32(owner.gid)
        w.u64(a.size)
        w.u64(a.bytesOnDisk)
        w.u32(0)  // rdev
        w.u32(0)
        w.u64(Self.fsid)
        w.u64(a.id)
        time(a.modified, into: &w)  // atime: not tracked, use mtime
        time(a.modified, into: &w)
        time(a.changed, into: &w)
    }

    private func time(_ date: Date, into w: inout XDRWriter) {
        let t = max(0, date.timeIntervalSince1970)
        let seconds = t.rounded(.down)
        w.u32(UInt32(clamping: Int64(seconds)))
        w.u32(UInt32(min(999_999_999, (t - seconds) * 1e9)))
    }
}
