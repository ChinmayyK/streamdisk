import Testing
@testable import StreamDiskCore

@Suite struct DriveFileSystemNamingTests {
    @Test func mapsSlashesAndReservedNames() {
        #expect(DriveFileSystem.displayName("a/b.mov") == "a:b.mov")
        #expect(DriveFileSystem.displayName("..") == "_..")
        #expect(DriveFileSystem.displayName("") == "_")
    }

    @Test func disambiguatesDuplicateNames() {
        let taken: [String: UInt64] = ["clip.mov": 1, "clip (2).mov": 2, "notes": 3]
        #expect(DriveFileSystem.uniqueName("clip.mov", taken: taken) == "clip (3).mov")
        #expect(DriveFileSystem.uniqueName("notes", taken: taken) == "notes (2)")
        #expect(DriveFileSystem.uniqueName("new.mov", taken: taken) == "new.mov")
    }

    @Test func idHashIsStableAndOrderSensitive() {
        var a = Hasher64(); a.combine("ab"); a.combine("c")
        var b = Hasher64(); b.combine("a"); b.combine("bc")
        var c = Hasher64(); c.combine("ab"); c.combine("c")
        #expect(a.value != b.value)
        #expect(a.value == c.value)
    }
}
