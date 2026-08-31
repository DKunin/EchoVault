import UniformTypeIdentifiers
import XCTest

@testable import EchoVault

final class LibraryImportTests: XCTestCase {
    func testFileImportModeAcceptsMultipleAudioFiles() {
        XCTAssertEqual(LibraryImportKind.files.allowedContentTypes, [.audio])
        XCTAssertTrue(LibraryImportKind.files.allowsMultipleSelection)
    }

    func testFolderImportModeAcceptsOneFolder() {
        XCTAssertEqual(LibraryImportKind.folder.allowedContentTypes, [.folder])
        XCTAssertFalse(LibraryImportKind.folder.allowsMultipleSelection)
    }
}
