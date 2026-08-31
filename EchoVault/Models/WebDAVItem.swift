import Foundation

struct WebDAVItem: Identifiable, Hashable, Sendable {
    let name: String
    let url: URL
    let isDirectory: Bool
    let contentLength: Int64?
    let lastModified: Date?
    let eTag: String?

    var id: String {
        url.absoluteString
    }
}

struct WebDAVLocation: Identifiable, Hashable, Sendable {
    let name: String
    let url: URL

    var id: String {
        url.absoluteString
    }
}
