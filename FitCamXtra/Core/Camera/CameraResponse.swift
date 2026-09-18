import Foundation

// Tolerant flat-XML reader. The firmware's XML templates vary per command and
// several are undocumented, so we collect every element's text rather than
// binding to one fixed shape. Foundation's XMLParser exists on Linux and
// Android via swift-corelibs-foundation, so this stays portable.

public struct CameraResponse: Sendable, Equatable {
    /// Every element's trimmed text, keyed by lowercased element name.
    /// Repeated elements keep every occurrence in `repeated`.
    public let values: [String: String]
    public let repeated: [String: [String]]
    public let raw: String

    public init(values: [String: String], repeated: [String: [String]], raw: String) {
        self.values = values
        self.repeated = repeated
        self.raw = raw
    }

    public func string(_ key: String) -> String? {
        values[key.lowercased()]
    }

    public func int(_ key: String) -> Int? {
        guard let text = string(key) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespaces))
    }

    public func list(_ key: String) -> [String] {
        repeated[key.lowercased()] ?? []
    }

    /// The firmware reports Status -256 for a command missing from its table.
    public var status: Int? { int("status") }
    /// The firmware's dispatcher answers -256 for a command number that is not
    /// in its table, which is how a unit with a different build says it cannot
    /// do something.
    public var isCommandUnsupported: Bool { status == -256 }
}

public enum CameraResponseParser {
    public static func parse(_ data: Data) throws -> CameraResponse {
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let delegate = FlatXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw CameraError.malformedResponse(raw)
        }
        return CameraResponse(values: delegate.values, repeated: delegate.repeated, raw: raw)
    }
}

private final class FlatXMLDelegate: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let key = elementName.lowercased()
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if values[key] == nil {
                values[key] = text
            }
            repeated[key, default: []].append(text)
        }
        buffer = ""
    }
}

public enum CameraError: Error, Sendable, Equatable {
    case notReachable
    case timedOut
    /// Something is at that address and actively said no. During a sweep this
    /// is the useful negative: it proves the phone can reach the network at
    /// all, which a timeout does not.
    case connectionRefused
    case malformedResponse(String)
    case commandFailed(command: Int, status: Int)
    case commandUnsupported(command: Int)
    case notConnected
}

extension CameraError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notReachable:
            return "The camera did not answer."
        case .timedOut:
            return "The camera took too long to answer."
        case .connectionRefused:
            return "That address refused the connection."
        case .malformedResponse:
            return "The camera sent a reply the app could not read."
        case .commandFailed(let command, let status):
            return "Camera command \(command) failed with status \(status)."
        case .commandUnsupported(let command):
            return "This camera does not support command \(command)."
        case .notConnected:
            return "Not connected to the camera."
        }
    }
}
