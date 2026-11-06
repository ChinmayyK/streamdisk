import Testing
@testable import NFSServer

@Suite struct XDRTests {
    @Test func roundTripsScalarsAndPadding() throws {
        var w = XDRWriter()
        w.u32(0xDEAD_BEEF)
        w.u64(0x0102_0304_0506_0708)
        w.bool(true)
        w.string("abcde")
        w.opaque([UInt8]())
        #expect(w.bytes.count == 4 + 8 + 4 + (4 + 8) + 4)

        var r = XDRReader(w.bytes)
        #expect(try r.u32() == 0xDEAD_BEEF)
        #expect(try r.u64() == 0x0102_0304_0506_0708)
        #expect(try r.bool())
        #expect(try r.string(max: 10) == "abcde")
        #expect(try r.opaque(max: 0) == [])
        #expect(r.remaining == 0)
    }

    @Test func rejectsTruncatedAndOversizedInput() {
        var short = XDRReader([0, 0, 0])
        #expect(throws: XDRError.truncated) { try short.u32() }

        var w = XDRWriter()
        w.u32(1_000_000)
        var huge = XDRReader(w.bytes)
        #expect(throws: XDRError.tooLong(1_000_000)) { try huge.opaque(max: 64) }
    }

    @Test func rejectsInvalidUTF8() {
        var w = XDRWriter()
        w.opaque([0xFF, 0xFE])
        var r = XDRReader(w.bytes)
        #expect(throws: XDRError.invalidString) { try r.string(max: 16) }
    }
}

@Suite struct RecordAssemblerTests {
    private func fragment(_ body: [UInt8], last: Bool) -> [UInt8] {
        let header = UInt32(body.count) | (last ? 0x8000_0000 : 0)
        return withUnsafeBytes(of: header.bigEndian, Array.init) + body
    }

    @Test func joinsFragmentsAcrossArbitrarySplits() throws {
        let stream = fragment([1, 2, 3], last: false) + fragment([4, 5], last: true) + fragment([9], last: true)
        // Feed one byte at a time: records must come out whole and in order.
        var a = RecordAssembler(maxRecordSize: 1024)
        var records: [[UInt8]] = []
        for byte in stream { records += try a.feed([byte]) }
        #expect(records == [[1, 2, 3, 4, 5], [9]])
    }

    @Test func rejectsRecordsOverTheLimit() {
        var a = RecordAssembler(maxRecordSize: 8)
        #expect(throws: RecordAssembler.Failure.self) {
            _ = try a.feed(fragment([UInt8](repeating: 0, count: 9), last: true))
        }
    }

    @Test func framesRepliesAsSingleLastFragment() {
        let framed = Array(RecordAssembler.frame([7, 7]))
        #expect(framed == [0x80, 0, 0, 2, 7, 7])
    }
}

@Suite struct RPCMessageTests {
    private func call(procedure: UInt32, auth: (flavor: UInt32, body: [UInt8])) -> [UInt8] {
        var w = XDRWriter()
        w.u32(42)  // xid
        w.u32(0)  // CALL
        w.u32(2)
        w.u32(100003)
        w.u32(3)
        w.u32(procedure)
        w.u32(auth.flavor)
        w.opaque(auth.body)
        w.u32(0)
        w.opaque([UInt8]())
        return w.bytes
    }

    @Test func decodesAuthSysCredentials() throws {
        var cred = XDRWriter()
        cred.u32(0)
        cred.string("mac")
        cred.u32(501)
        cred.u32(20)
        cred.u32(0)  // no supplementary groups
        let decoded = try RPCMessage.decodeCall(call(procedure: 1, auth: (1, cred.bytes)))
        #expect(decoded.xid == 42)
        #expect(decoded.procedure == 1)
        #expect(decoded.auth == .sys(uid: 501, gid: 20))
    }

    @Test func encodesAcceptedAndDeniedReplies() {
        #expect(RPCMessage.encodeReply(xid: 7, .procedureUnavailable).bytes
            == [0, 0, 0, 7, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3])
        #expect(RPCMessage.encodeReply(xid: 7, .authError(5)).bytes
            == [0, 0, 0, 7, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 5])
    }
}
