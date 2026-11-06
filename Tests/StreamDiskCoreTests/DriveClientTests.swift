import Foundation
import Testing
@testable import StreamDiskCore

@Suite struct DriveClientTests {
    @Test func decodesDriveFileWithStringSizeAndFractionalDates() throws {
        let json = """
            {"id":"abc","name":"trip.mov","mimeType":"video/quicktime","size":"48213551104",
             "modifiedTime":"2026-11-06T15:57:41.123Z","createdTime":"2026-11-01T08:00:00Z"}
            """
        let f = try DriveClient.decoder.decode(DriveFile.self, from: Data(json.utf8))
        #expect(f.size == 48_213_551_104)
        #expect(f.isStreamable && !f.isFolder)
        #expect(abs(f.modifiedTime.timeIntervalSince1970 - 1_793_980_661.123) < 0.0005)
    }

    @Test func googleNativeDocsAreNotStreamable() throws {
        let json = """
            {"id":"d","name":"Notes","mimeType":"application/vnd.google-apps.document",
             "modifiedTime":"2026-11-06T15:57:41Z","createdTime":"2026-11-06T15:57:41Z"}
            """
        let f = try DriveClient.decoder.decode(DriveFile.self, from: Data(json.utf8))
        #expect(f.size == 0)
        #expect(!f.isStreamable)
    }

    @Test func readsConfirmedBytesFromResumeResponse() {
        let url = URL(string: "https://example.com")!
        let partial = HTTPURLResponse(url: url, statusCode: 308, httpVersion: nil, headerFields: ["Range": "bytes=0-8388607"])!
        let none = HTTPURLResponse(url: url, statusCode: 308, httpVersion: nil, headerFields: [:])!
        #expect(DriveClient.confirmedBytes(partial) == 8_388_608)
        #expect(DriveClient.confirmedBytes(none) == 0)
    }

    @Test func classifiesTransientErrors() {
        #expect(DriveClient.isTransient(URLError(.networkConnectionLost)))
        #expect(DriveClient.isTransient(DriveError.http(status: 503, message: "")))
        #expect(DriveClient.isTransient(DriveError.http(status: 403, message: "Rate Limit Exceeded [userRateLimitExceeded]")))
        #expect(!DriveClient.isTransient(DriveError.http(status: 403, message: "insufficientPermissions")))
        #expect(!DriveClient.isTransient(DriveError.http(status: 404, message: "")))
    }

    @Test func cancellationIsNotRetried() {
        #expect(!DriveClient.isTransient(URLError(.cancelled)))
    }

    @Test func formatsTimestampsAsRFC3339() {
        #expect(DriveClient.timestamp(Date(timeIntervalSince1970: 1_793_980_661.5)) == "2026-11-06T15:57:41.500Z")
    }

    @Test func escapesQueryLiterals() {
        #expect(DriveClient.escape("it's") == "it\\'s")
    }

    @Test func formEncodesReservedCharacters() {
        #expect(String(decoding: GoogleAuth.form(["b": "a b&c", "a": "x/y"]), as: UTF8.self) == "a=x%2Fy&b=a%20b%26c")
    }
}
