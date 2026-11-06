import Foundation

// XDR (RFC 4506) encoding: big-endian, every item padded to a 4-byte boundary.

public enum XDRError: Error, Equatable {
    case truncated
    case tooLong(Int)
    case invalidString
}

public struct XDRWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 256) {
        bytes.reserveCapacity(capacity)
    }

    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func u64(_ v: UInt64) {
        u32(UInt32(truncatingIfNeeded: v >> 32))
        u32(UInt32(truncatingIfNeeded: v))
    }

    public mutating func bool(_ v: Bool) { u32(v ? 1 : 0) }

    /// Variable-length opaque: length prefix, bytes, zero padding.
    public mutating func opaque<C: Collection>(_ data: C) where C.Element == UInt8 {
        u32(UInt32(data.count))
        fixedOpaque(data)
    }

    /// Fixed-length opaque: bytes and zero padding, no length prefix.
    public mutating func fixedOpaque<C: Collection>(_ data: C) where C.Element == UInt8 {
        bytes.append(contentsOf: data)
        let pad = (4 - data.count % 4) % 4
        if pad > 0 { bytes.append(contentsOf: repeatElement(0, count: pad)) }
    }

    public mutating func string(_ s: String) { opaque(Array(s.utf8)) }

    public mutating func append(_ other: XDRWriter) { bytes.append(contentsOf: other.bytes) }
}

public struct XDRReader: Sendable {
    private let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw XDRError.truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    public mutating func u64() throws -> UInt64 {
        let hi = try u32()
        let lo = try u32()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    public mutating func bool() throws -> Bool { try u32() != 0 }

    /// Variable-length opaque with an upper bound, so a hostile length cannot allocate unbounded memory.
    public mutating func opaque(max: Int) throws -> [UInt8] {
        let n = Int(try u32())
        guard n <= max else { throw XDRError.tooLong(n) }
        return try fixedOpaque(n)
    }

    public mutating func fixedOpaque(_ n: Int) throws -> [UInt8] {
        let padded = n + (4 - n % 4) % 4
        guard remaining >= padded else { throw XDRError.truncated }
        defer { offset += padded }
        return Array(bytes[offset..<offset + n])
    }

    public mutating func string(max: Int) throws -> String {
        let raw = try opaque(max: max)
        guard let s = String(bytes: raw, encoding: .utf8) else { throw XDRError.invalidString }
        return s
    }

    public mutating func skip(_ n: Int) throws {
        guard remaining >= n else { throw XDRError.truncated }
        offset += n
    }
}
