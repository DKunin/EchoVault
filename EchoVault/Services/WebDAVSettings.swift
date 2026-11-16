import Foundation
import Observation

struct WebDAVEndpointMigration: Hashable, Sendable {
    let sourceRootURL: URL
    let destinationRootURL: URL

    func rebasedURL(for candidateURL: URL) -> URL? {
        guard Self.sameOrigin(candidateURL, sourceRootURL),
            var candidateComponents = URLComponents(
                url: candidateURL,
                resolvingAgainstBaseURL: false
            ),
            let destinationComponents = URLComponents(
                url: destinationRootURL,
                resolvingAgainstBaseURL: false
            ),
            let relativePath = Self.relativePercentEncodedPath(
                candidateComponents.percentEncodedPath,
                within: sourceRootURL
            )
        else {
            return nil
        }

        candidateComponents.scheme = destinationComponents.scheme?.lowercased()
        candidateComponents.host = destinationComponents.host?.lowercased()
        candidateComponents.port = destinationComponents.port
        candidateComponents.user = nil
        candidateComponents.password = nil
        candidateComponents.percentEncodedPath = Self.joinedPercentEncodedPath(
            rootURL: destinationRootURL,
            relativePath: relativePath
        )
        guard let rebasedURL = candidateComponents.url, rebasedURL != candidateURL else {
            return nil
        }
        return rebasedURL
    }

    static func inferredSourceRoot(
        for candidateURL: URL,
        destinationRootURL: URL
    ) -> URL? {
        guard
            var components = URLComponents(
                url: destinationRootURL,
                resolvingAgainstBaseURL: false
            )
        else {
            return nil
        }
        components.scheme = candidateURL.scheme?.lowercased()
        components.host = candidateURL.host?.lowercased()
        components.port = candidateURL.port
        components.user = nil
        components.password = nil
        return components.url
    }

    private static func relativePercentEncodedPath(
        _ candidatePath: String,
        within rootURL: URL
    ) -> String? {
        let rootPath = normalizedRootPath(rootURL)
        if candidatePath == String(rootPath.dropLast()) {
            return ""
        }
        guard candidatePath.hasPrefix(rootPath) else {
            return nil
        }
        return String(candidatePath.dropFirst(rootPath.count))
    }

    private static func joinedPercentEncodedPath(
        rootURL: URL,
        relativePath: String
    ) -> String {
        normalizedRootPath(rootURL) + relativePath
    }

    private static func normalizedRootPath(_ url: URL) -> String {
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        if path.isEmpty {
            path = "/"
        }
        if !path.hasSuffix("/") {
            path.append("/")
        }
        return path
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.caseInsensitiveCompare(rhs.scheme ?? "") == .orderedSame
            && lhs.host?.caseInsensitiveCompare(rhs.host ?? "") == .orderedSame
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

struct WebDAVConfiguration: Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case emptyEndpoint
        case invalidEndpoint
        case insecureHTTPRequiresOptIn
        case embeddedCredentialsNotAllowed
        case usernameContainsColon

        var errorDescription: String? {
            switch self {
            case .emptyEndpoint:
                return "Enter a WebDAV server address."
            case .invalidEndpoint:
                return "Enter a valid HTTP or HTTPS WebDAV server address with a host."
            case .insecureHTTPRequiresOptIn:
                return "Enable insecure HTTP access to connect without transport encryption."
            case .embeddedCredentialsNotAllowed:
                return "Enter credentials in the username and password fields, not in the server address."
            case .usernameContainsColon:
                return "The username cannot contain a colon."
            }
        }
    }

    let rootURL: URL
    let username: String
    let password: String

    init(
        endpoint: String,
        username: String,
        password: String,
        allowsInsecureHTTP: Bool = false
    ) throws {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            throw ValidationError.emptyEndpoint
        }
        guard var components = URLComponents(string: trimmedEndpoint),
            components.host?.isEmpty == false
        else {
            throw ValidationError.invalidEndpoint
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw ValidationError.invalidEndpoint
        }
        guard scheme != "http" || allowsInsecureHTTP else {
            throw ValidationError.insecureHTTPRequiresOptIn
        }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.embeddedCredentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw ValidationError.invalidEndpoint
        }
        guard !username.contains(":") else {
            throw ValidationError.usernameContainsColon
        }

        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        } else if !path.hasSuffix("/") {
            path += "/"
        }
        components.scheme = scheme
        components.percentEncodedPath = path
        guard let normalizedURL = components.url else {
            throw ValidationError.invalidEndpoint
        }

        self.rootURL = normalizedURL
        self.username = username
        self.password = password
    }

    func permits(_ candidate: URL) -> Bool {
        guard candidate.user == nil,
            candidate.password == nil,
            rootURL.scheme?.caseInsensitiveCompare(candidate.scheme ?? "") == .orderedSame,
            rootURL.host?.caseInsensitiveCompare(candidate.host ?? "") == .orderedSame,
            effectivePort(for: rootURL) == effectivePort(for: candidate)
        else {
            return false
        }

        let normalizedRootPath = rootURL.standardized.path
        let candidatePath = candidate.standardized.path
        let rootPath =
            normalizedRootPath == "/"
            ? "/"
            : normalizedRootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .withLeadingSlash
        let rootPrefix = rootPath == "/" ? "/" : "\(rootPath)/"
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPrefix)
    }

    func permits(_ protectionSpace: URLProtectionSpace) -> Bool {
        guard rootURL.host?.caseInsensitiveCompare(protectionSpace.host) == .orderedSame,
            rootURL.scheme?.caseInsensitiveCompare(protectionSpace.protocol ?? "") == .orderedSame
        else {
            return false
        }
        return effectivePort(for: rootURL) == protectionSpace.port
    }

    private func effectivePort(for url: URL) -> Int {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }
}

enum WebDAVConnectionErrorMessage {
    static func message(for error: any Error) -> String {
        if let clientError = error as? WebDAVClient.ClientError {
            switch clientError {
            case .authenticationRequired:
                return "The server rejected these credentials. Check the username and password, then try again."
            case .forbidden:
                return "The account connected, but it cannot access this folder. Check the path and server permissions."
            case .httpStatus(404):
                return "The WebDAV folder was not found. Check the full server path."
            default:
                return clientError.localizedDescription
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "This device is offline. Reconnect to the network and try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "The server could not be reached. Check its address, port, and your network connection."
            case .timedOut:
                return "The server did not respond in time. Check the address and try again."
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
                return
                    "A secure connection could not be established. Check the server certificate or use its correct HTTPS address."
            default:
                return urlError.localizedDescription
            }
        }

        return error.localizedDescription
    }
}

private extension String {
    var withLeadingSlash: String {
        hasPrefix("/") ? self : "/\(self)"
    }
}

@MainActor
@Observable
final class WebDAVSettings {
    private enum Keys {
        static let endpoint = "webdav.endpoint"
        static let username = "webdav.username"
        static let allowsInsecureHTTP = "webdav.allowsInsecureHTTP"
        static let passwordAccount = "webdav.password"
    }

    private(set) var endpoint: String
    private(set) var username: String
    private(set) var password: String
    private(set) var allowsInsecureHTTP: Bool
    private(set) var credentialLoadError: String?
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(service: "com.example.EchoVault.webdav")
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        self.username = defaults.string(forKey: Keys.username) ?? ""
        self.allowsInsecureHTTP = defaults.bool(forKey: Keys.allowsInsecureHTTP)
        do {
            self.password = try keychain.read(account: Keys.passwordAccount) ?? ""
            self.credentialLoadError = nil
        } catch {
            self.password = ""
            self.credentialLoadError = error.localizedDescription
        }
    }

    var configuration: WebDAVConfiguration? {
        try? WebDAVConfiguration(
            endpoint: endpoint,
            username: username,
            password: password,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
    }

    func save(
        endpoint: String,
        username: String,
        password: String,
        allowsInsecureHTTP: Bool
    ) throws {
        let configuration = try WebDAVConfiguration(
            endpoint: endpoint,
            username: username,
            password: password,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        try keychain.set(password, account: Keys.passwordAccount)

        defaults.set(configuration.rootURL.absoluteString, forKey: Keys.endpoint)
        defaults.set(username, forKey: Keys.username)
        defaults.set(allowsInsecureHTTP, forKey: Keys.allowsInsecureHTTP)
        self.endpoint = configuration.rootURL.absoluteString
        self.username = username
        self.password = password
        self.allowsInsecureHTTP = allowsInsecureHTTP
        credentialLoadError = nil
        revision += 1
    }
}
