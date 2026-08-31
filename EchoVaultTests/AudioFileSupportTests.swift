import XCTest

@testable import EchoVault

final class AudioFileSupportTests: XCTestCase {
    func testRecognizesSupportedExtensionsCaseInsensitively() {
        XCTAssertTrue(AudioFileSupport.isSupported(URL(fileURLWithPath: "/music/Track.MP3")))
        XCTAssertTrue(AudioFileSupport.isSupported(URL(fileURLWithPath: "/music/Track.flac")))
        XCTAssertFalse(AudioFileSupport.isSupported(URL(fileURLWithPath: "/music/cover.jpg")))
    }

    func testBuildsReadableTitle() {
        XCTAssertEqual(
            AudioFileSupport.displayTitle(for: "Northern%20Lights.m4a"),
            "Northern Lights"
        )
    }
}
