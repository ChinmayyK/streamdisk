import Foundation

/// NFSv3 procedures that change the file system (RFC 1813 §3.3.2-3.3.21).
extension NFSProgram {
    func handleWrite(_ procedure: Procedure, _ args: inout XDRReader,
                     _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        switch procedure {
        case .setattr: return try await setattr(&args, fs)
        case .write: return try await write(&args, fs)
        case .create: return try await create(&args, fs)
        case .mkdir: return try await mkdir(&args, fs)
        case .remove: return try await remove(&args, fs, directory: false)
        case .rmdir: return try await remove(&args, fs, directory: true)
        case .rename: return try await rename(&args, fs)
        case .commit: return try await commit(&args, fs)
        default: return failure(.notSupported, wcc: 1)
        }
    }

    /// The parts of sattr3 StreamDisk honours. Mode, owner and access time are accepted and ignored.
    struct SetAttributes {
        var size: UInt64?
        var modified: Date?
        var isEmpty: Bool { size == nil && modified == nil }
    }

    func setAttributesArgument(_ r: inout XDRReader) throws -> SetAttributes {
        var out = SetAttributes()
        if try r.bool() { _ = try r.u32() }  // mode
        if try r.bool() { _ = try r.u32() }  // uid
        if try r.bool() { _ = try r.u32() }  // gid
        if try r.bool() { out.size = try r.u64() }
        if try r.u32() == 2 { try r.skip(8) }  // atime: only SET_TO_CLIENT_TIME carries a value
        switch try r.u32() {
        case 1: out.modified = Date()
        case 2:
            let seconds = try r.u32()
            let nanos = try r.u32()
            out.modified = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1e9)
        default: break
        }
        return out
    }

    /// wcc_data with no pre-operation attributes: clients then simply refresh their cache.
    func wcc(_ attrs: FileAttributes?, into w: inout XDRWriter) {
        w.bool(false)
        postOp(attrs, into: &w)
    }

    private func setattr(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        let change = try setAttributesArgument(&args)
        if try args.bool() { try args.skip(8) }  // guard ctime: not enforced
        var w = XDRWriter()
        do {
            let attrs = change.isEmpty
                ? try await fs.attributes(of: id)
                : try await fs.setAttributes(id, size: change.size, modified: change.modified)
            w.u32(NFSStatus.ok.rawValue)
            wcc(attrs, into: &w)
        } catch {
            w.u32(status(error).rawValue)
            wcc(try? await fs.attributes(of: id), into: &w)
        }
        return w
    }

    private func write(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        let offset = try args.u64()
        let count = Int(try args.u32())
        let stable = try args.u32()
        let data = try args.opaque(max: Int(Self.maxTransfer))
        var w = XDRWriter()
        do {
            guard data.count == count else { throw NFSStatus.inval }
            let attrs = try await fs.write(id, offset: offset, data: data)
            if stable != 0 { try await fs.commit(id) }
            w.u32(NFSStatus.ok.rawValue)
            wcc(attrs, into: &w)
            w.u32(UInt32(data.count))
            w.u32(stable == 0 ? 0 : 2)  // UNSTABLE, or FILE_SYNC once committed
            w.u64(writeVerifier)
        } catch {
            w.u32(status(error).rawValue)
            wcc(try? await fs.attributes(of: id), into: &w)
        }
        return w
    }

    private func create(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        let dirID = try handleArgument(&args)
        let name = try args.string(max: 255)
        let how = try args.u32()
        let mode: CreateMode
        var initial = SetAttributes()
        switch how {
        case 0: mode = .unchecked; initial = try setAttributesArgument(&args)
        case 1: mode = .guarded; initial = try setAttributesArgument(&args)
        default: mode = .exclusive(try args.u64())
        }
        return await created(dirID, fs) {
            var attrs = try await fs.create(name, in: dirID, mode: mode)
            if !initial.isEmpty {
                attrs = try await fs.setAttributes(attrs.id, size: initial.size, modified: initial.modified)
            }
            return attrs
        }
    }

    private func mkdir(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        let dirID = try handleArgument(&args)
        let name = try args.string(max: 255)
        _ = try setAttributesArgument(&args)
        return await created(dirID, fs) { try await fs.makeDirectory(name, in: dirID) }
    }

    /// CREATE and MKDIR share a result shape: new handle and attributes, then the directory's wcc.
    private func created(_ dirID: UInt64, _ fs: any WritableFileSystemBackend,
                         _ make: () async throws -> FileAttributes) async -> XDRWriter {
        var w = XDRWriter()
        do {
            let attrs = try await make()
            w.u32(NFSStatus.ok.rawValue)
            w.bool(true)
            w.opaque(FileHandle.encode(attrs.id))
            postOp(attrs, into: &w)
        } catch {
            w.u32(status(error).rawValue)
        }
        wcc(try? await fs.attributes(of: dirID), into: &w)
        return w
    }

    private func remove(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend, directory: Bool) async throws -> XDRWriter {
        let dirID = try handleArgument(&args)
        let name = try args.string(max: 255)
        var w = XDRWriter()
        do {
            if directory {
                try await fs.removeDirectory(name, from: dirID)
            } else {
                try await fs.remove(name, from: dirID)
            }
            w.u32(NFSStatus.ok.rawValue)
        } catch {
            w.u32(status(error).rawValue)
        }
        wcc(try? await fs.attributes(of: dirID), into: &w)
        return w
    }

    private func rename(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        let fromID = try handleArgument(&args)
        let fromName = try args.string(max: 255)
        let toID = try handleArgument(&args)
        let toName = try args.string(max: 255)
        var w = XDRWriter()
        do {
            try await fs.rename(fromName, from: fromID, to: toName, in: toID)
            w.u32(NFSStatus.ok.rawValue)
        } catch {
            w.u32(status(error).rawValue)
        }
        wcc(try? await fs.attributes(of: fromID), into: &w)
        wcc(try? await fs.attributes(of: toID), into: &w)
        return w
    }

    private func commit(_ args: inout XDRReader, _ fs: any WritableFileSystemBackend) async throws -> XDRWriter {
        let id = try handleArgument(&args)
        _ = try args.u64()  // offset and count: the whole file is committed
        _ = try args.u32()
        var w = XDRWriter()
        do {
            try await fs.commit(id)
            w.u32(NFSStatus.ok.rawValue)
            wcc(try? await fs.attributes(of: id), into: &w)
            w.u64(writeVerifier)
        } catch {
            w.u32(status(error).rawValue)
            wcc(try? await fs.attributes(of: id), into: &w)
        }
        return w
    }
}
