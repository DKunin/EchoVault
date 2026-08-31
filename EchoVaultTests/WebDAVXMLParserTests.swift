import XCTest

@testable import EchoVault

final class WebDAVXMLParserTests: XCTestCase {
    func testParsesNamespacedMultiStatusResponse() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/music/</d:href>
                <d:propstat>
                  <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
              <d:response>
                <d:href>/music/Album/</d:href>
                <d:propstat>
                  <d:prop>
                    <d:resourcetype><d:collection/></d:resourcetype>
                    <d:getlastmodified>Sun, 06 Nov 1994 08:49:37 GMT</d:getlastmodified>
                  </d:prop>
                </d:propstat>
              </d:response>
              <d:response>
                <d:href>/music/Northern%20Lights.m4a</d:href>
                <d:propstat>
                  <d:prop>
                    <d:resourcetype/>
                    <d:getcontentlength>2048</d:getcontentlength>
                    <d:getetag>&quot;abc123&quot;</d:getetag>
                  </d:prop>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """

        let resources = try WebDAVXMLParser().parse(Data(xml.utf8))

        XCTAssertEqual(resources.count, 3)
        XCTAssertTrue(resources[0].isCollection)
        XCTAssertEqual(resources[1].href, "/music/Album/")
        XCTAssertNotNil(resources[1].lastModified)
        XCTAssertFalse(resources[2].isCollection)
        XCTAssertEqual(resources[2].contentLength, 2_048)
        XCTAssertEqual(resources[2].eTag, "\"abc123\"")
    }

    func testRejectsMalformedXML() {
        let malformed = Data("<d:multistatus><d:response>".utf8)

        XCTAssertThrowsError(try WebDAVXMLParser().parse(malformed))
    }
}
