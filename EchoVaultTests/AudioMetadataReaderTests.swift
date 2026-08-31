import XCTest

@testable import EchoVault

final class AudioMetadataReaderTests: XCTestCase {
    func testReadsCommonMetadataAndArtwork() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "tagged-tone", withExtension: "m4a")
        )

        let metadata = try await AVAudioMetadataReader().readMetadata(from: fixtureURL)

        XCTAssertEqual(metadata.title, "Tagged Tone")
        XCTAssertEqual(metadata.artist, "Echo Artist")
        XCTAssertEqual(metadata.albumTitle, "Echo Album")
        XCTAssertFalse(try XCTUnwrap(metadata.artworkData).isEmpty)
    }
}
