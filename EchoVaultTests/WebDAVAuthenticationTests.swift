import XCTest

@testable import EchoVault

final class WebDAVAuthenticationTests: XCTestCase {
    func testUsesConfiguredCredentialForBasicAndDigestChallenges() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "http://dav.example.com/music/",
            username: "listener",
            password: "secret",
            allowsInsecureHTTP: true
        )
        let delegate = WebDAVRequestDelegate(configuration: configuration)

        for authenticationMethod in [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
        ] {
            let task = URLSession.shared.dataTask(with: configuration.rootURL)
            let result = ChallengeResultBox()
            delegate.urlSession(
                .shared,
                task: task,
                didReceive: challenge(
                    authenticationMethod: authenticationMethod,
                    host: "dav.example.com",
                    port: 80
                )
            ) { disposition, credential in
                result.set(disposition: disposition, credential: credential)
            }
            task.cancel()

            let snapshot = result.snapshot()
            XCTAssertEqual(snapshot.disposition, .useCredential)
            XCTAssertEqual(snapshot.credential?.user, "listener")
            XCTAssertEqual(snapshot.credential?.password, "secret")
            XCTAssertEqual(snapshot.credential?.persistence, .forSession)
        }
    }

    func testCancelsRepeatedOrOutOfScopeAuthenticationChallenges() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "https://dav.example.com/music/",
            username: "listener",
            password: "secret"
        )
        let delegate = WebDAVRequestDelegate(configuration: configuration)
        let task = URLSession.shared.dataTask(with: configuration.rootURL)

        for challenge in [
            challenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
                host: "dav.example.com",
                port: 443,
                previousFailureCount: 1
            ),
            challenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
                host: "evil.example.com",
                port: 443
            ),
            challenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
                host: "dav.example.com",
                port: 8443
            ),
            challenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
                host: "dav.example.com",
                port: 443,
                protocol: "http"
            ),
        ] {
            let result = ChallengeResultBox()
            delegate.urlSession(.shared, task: task, didReceive: challenge) {
                disposition,
                credential in
                result.set(disposition: disposition, credential: credential)
            }
            let snapshot = result.snapshot()
            XCTAssertEqual(snapshot.disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(snapshot.credential)
        }
        task.cancel()
    }

    func testLeavesUnrelatedChallengesToSystemHandling() throws {
        let configuration = try WebDAVConfiguration(
            endpoint: "https://dav.example.com/music/",
            username: "listener",
            password: "secret"
        )
        let delegate = WebDAVRequestDelegate(configuration: configuration)
        let task = URLSession.shared.dataTask(with: configuration.rootURL)
        let result = ChallengeResultBox()

        delegate.urlSession(
            .shared,
            task: task,
            didReceive: challenge(
                authenticationMethod: NSURLAuthenticationMethodClientCertificate,
                host: "dav.example.com",
                port: 443
            )
        ) { disposition, credential in
            result.set(disposition: disposition, credential: credential)
        }
        task.cancel()

        let snapshot = result.snapshot()
        XCTAssertEqual(snapshot.disposition, .performDefaultHandling)
        XCTAssertNil(snapshot.credential)
    }

    private func challenge(
        authenticationMethod: String,
        host: String,
        port: Int,
        protocol: String? = nil,
        previousFailureCount: Int = 0
    ) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: host,
                port: port,
                protocol: `protocol` ?? (port == 80 ? "http" : "https"),
                realm: "WebDAV",
                authenticationMethod: authenticationMethod
            ),
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: AuthenticationChallengeSender()
        )
    }
}

private final class ChallengeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var disposition: URLSession.AuthChallengeDisposition?
    private var credential: URLCredential?

    func set(
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?
    ) {
        lock.withLock {
            self.disposition = disposition
            self.credential = credential
        }
    }

    func snapshot() -> (
        disposition: URLSession.AuthChallengeDisposition?,
        credential: URLCredential?
    ) {
        lock.withLock {
            (disposition, credential)
        }
    }
}

private final class AuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

    func cancel(_ challenge: URLAuthenticationChallenge) {}

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
