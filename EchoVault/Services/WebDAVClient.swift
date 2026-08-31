import Foundation

final class WebDAVRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let configuration: WebDAVConfiguration

    init(configuration: WebDAVConfiguration) {
        self.configuration = configuration
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destinationURL = request.url, configuration.permits(destinationURL) else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
    ) {
        let authenticationMethod = challenge.protectionSpace.authenticationMethod
        guard
            authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                || authenticationMethod == NSURLAuthenticationMethodHTTPDigest
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount == 0,
            let requestURL = task.currentRequest?.url,
            configuration.permits(requestURL),
            configuration.permits(challenge.protectionSpace),
            !configuration.username.isEmpty || !configuration.password.isEmpty
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(
            .useCredential,
            URLCredential(
                user: configuration.username,
                password: configuration.password,
                persistence: .forSession
            )
        )
    }
}

struct WebDAVClient {
    enum ClientError: LocalizedError, Equatable {
        case invalidResponse
        case authenticationRequired
        case forbidden
        case httpStatus(Int)
        case serverRedirectedOutsideConfiguredLocation
        case itemOutsideConfiguredLocation
        case notAnAudioFile
        case folderTraversalLimitExceeded

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The WebDAV server returned an invalid response."
            case .authenticationRequired:
                return "The WebDAV server rejected the username or password."
            case .forbidden:
                return "The WebDAV server denied access to this location."
            case .httpStatus(let status):
                return "The WebDAV server returned HTTP \(status)."
            case .serverRedirectedOutsideConfiguredLocation:
                return "The server redirected the request outside the configured WebDAV location."
            case .itemOutsideConfiguredLocation:
                return "The requested item is outside the configured WebDAV location."
            case .notAnAudioFile:
                return "This WebDAV item is not a supported audio file."
            case .folderTraversalLimitExceeded:
                return "This WebDAV folder contains too many nested folders to process safely."
            }
        }
    }

    let configuration: WebDAVConfiguration
    private let session: URLSession

    init(configuration: WebDAVConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.waitsForConnectivity = true
            sessionConfiguration.timeoutIntervalForRequest = 30
            sessionConfiguration.timeoutIntervalForResource = 300
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    func listDirectory(at directoryURL: URL) async throws -> [WebDAVItem] {
        guard configuration.permits(directoryURL) else {
            throw ClientError.itemOutsideConfiguredLocation
        }

        let request = makeRequest(
            url: directoryURL,
            method: "PROPFIND",
            depth: "1",
            body: Self.propertyRequestBody
        )
        let (data, response) = try await session.data(
            for: request,
            delegate: WebDAVRequestDelegate(configuration: configuration)
        )
        try validate(response: response, acceptedStatusCodes: [200, 207])

        let parsedResources = try WebDAVXMLParser().parse(data)
        let directoryPath = directoryURL.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return parsedResources.compactMap { resource in
            guard let resolvedURL = URL(string: resource.href, relativeTo: directoryURL)?.absoluteURL else {
                return nil
            }
            let resourceURL =
                resource.isCollection
                ? Self.normalizedDirectoryURL(resolvedURL)
                : resolvedURL
            guard
                configuration.permits(resourceURL)
            else {
                return nil
            }

            let resourcePath = resourceURL.standardized.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard resourcePath != directoryPath else {
                return nil
            }

            let name =
                resourceURL.lastPathComponent.removingPercentEncoding
                ?? resourceURL.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else {
                return nil
            }
            guard resource.isCollection || AudioFileSupport.isSupported(resourceURL) else {
                return nil
            }

            return WebDAVItem(
                name: name,
                url: resourceURL,
                isDirectory: resource.isCollection,
                contentLength: resource.contentLength,
                lastModified: resource.lastModified,
                eTag: resource.eTag
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func checkConnection() async throws {
        let request = makeRequest(
            url: configuration.rootURL,
            method: "PROPFIND",
            depth: "0",
            body: Self.propertyRequestBody
        )
        let (_, response) = try await session.data(
            for: request,
            delegate: WebDAVRequestDelegate(configuration: configuration)
        )
        try validate(response: response, acceptedStatusCodes: [200, 207])
    }

    func listAudioFilesRecursively(at directoryURL: URL) async throws -> [WebDAVItem] {
        guard configuration.permits(directoryURL) else {
            throw ClientError.itemOutsideConfiguredLocation
        }

        var pendingDirectories = [Self.normalizedDirectoryURL(directoryURL)]
        var visitedDirectories = Set<String>()
        var audioItemsByURL: [URL: WebDAVItem] = [:]

        while let currentDirectory = pendingDirectories.popLast() {
            try Task.checkCancellation()
            let directoryKey = currentDirectory.standardized.absoluteString
            guard visitedDirectories.insert(directoryKey).inserted else {
                continue
            }
            guard visitedDirectories.count <= 10_000 else {
                throw ClientError.folderTraversalLimitExceeded
            }

            for item in try await listDirectory(at: currentDirectory) {
                if item.isDirectory {
                    pendingDirectories.append(item.url)
                } else {
                    audioItemsByURL[item.url] = item
                }
            }
        }

        return audioItemsByURL.values.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    func download(_ item: WebDAVItem) async throws -> URL {
        guard !item.isDirectory, AudioFileSupport.isSupported(item.url) else {
            throw ClientError.notAnAudioFile
        }
        guard configuration.permits(item.url) else {
            throw ClientError.itemOutsideConfiguredLocation
        }

        let request = makeRequest(url: item.url, method: "GET")
        let (temporaryURL, response) = try await session.download(
            for: request,
            delegate: WebDAVRequestDelegate(configuration: configuration)
        )
        try validate(response: response, acceptedStatusCodes: Set(200...299))

        let durableTemporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoVault-\(UUID().uuidString)")
            .appendingPathExtension(item.url.pathExtension.lowercased())
        try FileManager.default.moveItem(at: temporaryURL, to: durableTemporaryURL)
        return durableTemporaryURL
    }

    private func makeRequest(
        url: URL,
        method: String,
        depth: String? = nil,
        body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("EchoVault/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }
        return request
    }

    private func validate(response: URLResponse, acceptedStatusCodes: Set<Int>) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        if (300..<400).contains(httpResponse.statusCode),
            let location = httpResponse.value(forHTTPHeaderField: "Location"),
            let redirectURL = URL(string: location, relativeTo: httpResponse.url),
            !configuration.permits(redirectURL.absoluteURL)
        {
            throw ClientError.serverRedirectedOutsideConfiguredLocation
        }
        guard let finalURL = httpResponse.url, configuration.permits(finalURL) else {
            throw ClientError.serverRedirectedOutsideConfiguredLocation
        }
        switch httpResponse.statusCode {
        case 401:
            throw ClientError.authenticationRequired
        case 403:
            throw ClientError.forbidden
        default:
            guard acceptedStatusCodes.contains(httpResponse.statusCode) else {
                throw ClientError.httpStatus(httpResponse.statusCode)
            }
        }
    }

    private static let propertyRequestBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getetag/>
          </d:prop>
        </d:propfind>
        """.utf8
    )

    private static func normalizedDirectoryURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url
        }
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url ?? url
    }
}
