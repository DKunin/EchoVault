import XCTest

@testable import EchoVault

final class WebDAVClientTests: XCTestCase {
    func testChecksHTTPConnectionWhenExplicitlyAllowed() async throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "http://dav.example.com/music/",
            username: "listener",
            password: "secret",
            allowsInsecureHTTP: true
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HTTPConnectionURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        try await WebDAVClient(configuration: configuration, session: session)
            .checkConnection()
    }

    func testListsFoldersAndAudioWhileFilteringUnsafeOrUnsupportedItems() async throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "https://dav.example.com/music/",
            username: "listener",
            password: "secret"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ListingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        let items = try await WebDAVClient(
            configuration: configuration,
            session: session
        )
        .listDirectory(at: configuration.rootURL)

        XCTAssertEqual(items.map(\.name), ["Album", "Northern Lights.m4a"])
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertTrue(items[0].url.absoluteString.hasSuffix("/"))
        XCTAssertFalse(items[1].isDirectory)
        XCTAssertEqual(items[1].contentLength, 2_048)
    }

    func testListsAudioRecursivelyAcrossNestedFolders() async throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "https://dav.example.com/music/",
            username: "listener",
            password: "secret"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecursiveListingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        let items = try await WebDAVClient(
            configuration: configuration,
            session: session
        )
        .listAudioFilesRecursively(at: configuration.rootURL)

        XCTAssertEqual(
            items.map(\.name),
            ["Album Track.mp3", "Deep Track.flac", "Root Track.m4a"]
        )
        XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
    }
}

private final class HTTPConnectionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let isExpectedRequest =
            request.url?.absoluteString == "http://dav.example.com/music/"
            && request.httpMethod == "PROPFIND"
            && request.value(forHTTPHeaderField: "Depth") == "0"
            && request.value(forHTTPHeaderField: "Authorization") == nil
        guard
            let requestURL = request.url,
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: isExpectedRequest ? 207 : 400,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ListingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let hasExpectedHeaders =
            request.httpMethod == "PROPFIND"
            && request.value(forHTTPHeaderField: "Depth") == "1"
            && request.value(forHTTPHeaderField: "Authorization") == nil
        let statusCode = hasExpectedHeaders ? 207 : 400
        guard
            let requestURL = request.url,
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/xml"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseXML.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let responseXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/music/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/music/Album</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/music/Northern%20Lights.m4a</d:href>
            <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>2048</d:getcontentlength></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/music/cover.jpg</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>https://evil.example/music/stolen.mp3</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/music-other/outside.mp3</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """
}

private final class RecursiveListingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url,
            request.httpMethod == "PROPFIND",
            request.value(forHTTPHeaderField: "Depth") == "1",
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 207,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/xml"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let body: String
        let path = requestURL.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        switch path {
        case "music":
            body = Self.multistatus(
                """
                <d:response><d:href>/music/Album/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
                <d:response><d:href>/music/Root%20Track.m4a</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
                """
            )
        case "music/Album":
            body = Self.multistatus(
                """
                <d:response><d:href>/music/Album/Disc%202/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
                <d:response><d:href>/music/Album/Album%20Track.mp3</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
                """
            )
        case "music/Album/Disc 2":
            body = Self.multistatus(
                """
                <d:response><d:href>/music/Album/Disc%202/Deep%20Track.flac</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
                """
            )
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func multistatus(_ responses: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          \(responses)
        </d:multistatus>
        """
    }
}
