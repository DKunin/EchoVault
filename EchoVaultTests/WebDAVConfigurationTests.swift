import XCTest

@testable import EchoVault

final class WebDAVConfigurationTests: XCTestCase {
    func testNormalizesRootURL() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: " https://dav.example.com/music ",
            username: "listener",
            password: "secret"
        )

        XCTAssertEqual(configuration.rootURL.absoluteString, "https://dav.example.com/music/")
    }

    func testRejectsHTTPWithoutExplicitOptIn() {
        XCTAssertThrowsError(
            try WebDAVConfiguration(
                endpoint: "http://dav.example.com/music",
                username: "",
                password: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? WebDAVConfiguration.ValidationError,
                .insecureHTTPRequiresOptIn
            )
        }
    }

    func testAcceptsHTTPWithExplicitOptIn() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: " HTTP://dav.example.com/music ",
            username: "listener",
            password: "secret",
            allowsInsecureHTTP: true
        )

        XCTAssertEqual(configuration.rootURL.absoluteString, "http://dav.example.com/music/")
    }

    func testHTTPUsesPort80AndStillRestrictsSchemeAndPort() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "http://dav.example.com/music/",
            username: "",
            password: "",
            allowsInsecureHTTP: true
        )

        XCTAssertTrue(
            configuration.permits(
                try XCTUnwrap(URL(string: "http://dav.example.com:80/music/song.mp3"))
            )
        )
        XCTAssertFalse(
            configuration.permits(
                try XCTUnwrap(URL(string: "http://dav.example.com:8080/music/song.mp3"))
            )
        )
        XCTAssertFalse(
            configuration.permits(
                try XCTUnwrap(URL(string: "https://dav.example.com/music/song.mp3"))
            )
        )
    }

    func testRejectsCredentialsEmbeddedInEndpoint() {
        XCTAssertThrowsError(
            try WebDAVConfiguration(
                endpoint: "https://user:secret@dav.example.com/music/",
                username: "",
                password: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? WebDAVConfiguration.ValidationError,
                .embeddedCredentialsNotAllowed
            )
        }
    }

    func testPermitsOnlyConfiguredOriginAndPath() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "https://dav.example.com/music/",
            username: "",
            password: ""
        )

        XCTAssertTrue(configuration.permits(try XCTUnwrap(URL(string: "https://dav.example.com/music/"))))
        XCTAssertTrue(configuration.permits(try XCTUnwrap(URL(string: "https://dav.example.com/music/album/song.mp3"))))
        XCTAssertFalse(
            configuration.permits(try XCTUnwrap(URL(string: "https://dav.example.com/music-other/song.mp3"))))
        XCTAssertFalse(
            configuration.permits(try XCTUnwrap(URL(string: "https://dav.example.com/music/../private/song.mp3"))))
        XCTAssertFalse(configuration.permits(try XCTUnwrap(URL(string: "https://evil.example/music/song.mp3"))))
        XCTAssertFalse(configuration.permits(try XCTUnwrap(URL(string: "http://dav.example.com/music/song.mp3"))))
    }

    func testAnonymousConfigurationIsAccepted() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "https://dav.example.com/",
            username: "",
            password: ""
        )

        XCTAssertEqual(configuration.username, "")
        XCTAssertEqual(configuration.password, "")
    }

    func testConnectionErrorsProvideActionableGuidance() {
        XCTAssertEqual(
            WebDAVConnectionErrorMessage.message(for: WebDAVClient.ClientError.authenticationRequired),
            "The server rejected these credentials. Check the username and password, then try again."
        )
        XCTAssertEqual(
            WebDAVConnectionErrorMessage.message(for: URLError(.cannotConnectToHost)),
            "The server could not be reached. Check its address, port, and your network connection."
        )
    }
}
