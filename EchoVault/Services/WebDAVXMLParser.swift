import Foundation

struct ParsedWebDAVResource: Equatable {
    let href: String
    let isCollection: Bool
    let contentLength: Int64?
    let lastModified: Date?
    let eTag: String?
}

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    enum ParseError: LocalizedError {
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .malformedResponse(let detail):
                return "The WebDAV server returned invalid XML: \(detail)"
            }
        }
    }

    private struct PendingResource {
        var href: String?
        var isCollection = false
        var contentLength: Int64?
        var lastModified: Date?
        var eTag: String?
    }

    private var resources: [ParsedWebDAVResource] = []
    private var currentResource: PendingResource?
    private var text = ""
    private var parserFailure: Error?
    private let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    func parse(_ data: Data) throws -> [ParsedWebDAVResource] {
        resources = []
        currentResource = nil
        text = ""
        parserFailure = nil

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let detail =
                parser.parserError?.localizedDescription
                ?? parserFailure?.localizedDescription
                ?? "Unknown parser error."
            throw ParseError.malformedResponse(detail)
        }
        return resources
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch localName(elementName) {
        case "response":
            currentResource = PendingResource()
        case "collection":
            currentResource?.isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(elementName) {
        case "href":
            currentResource?.href = value
        case "getcontentlength":
            currentResource?.contentLength = Int64(value)
        case "getlastmodified":
            currentResource?.lastModified = httpDateFormatter.date(from: value)
        case "getetag":
            currentResource?.eTag = value.isEmpty ? nil : value
        case "response":
            if let currentResource, let href = currentResource.href {
                resources.append(
                    ParsedWebDAVResource(
                        href: href,
                        isCollection: currentResource.isCollection,
                        contentLength: currentResource.contentLength,
                        lastModified: currentResource.lastModified,
                        eTag: currentResource.eTag
                    )
                )
            }
            currentResource = nil
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserFailure = parseError
    }

    private func localName(_ qualifiedName: String) -> String {
        qualifiedName.split(separator: ":").last.map(String.init)?.lowercased()
            ?? qualifiedName.lowercased()
    }
}
