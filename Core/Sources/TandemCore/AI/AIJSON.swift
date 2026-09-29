import Foundation

/// A minimal JSON document model used to build provider request bodies.
///
/// Objects are written with sorted keys so bodies are byte-for-byte deterministic, and `.base64`
/// writes image bytes straight into the output buffer (no intermediate `String`, no escaping pass),
/// which matters for multi-megabyte screenshots repeated across turns.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    /// A JSON string made of `prefix` followed by the base64 encoding (no line breaks) of `data`.
    case base64(Data, prefix: String)

    /// Serializes the value as compact UTF-8 JSON with sorted object keys.
    func serialized() -> Data {
        var output: [UInt8] = []
        output.reserveCapacity(estimatedSize)
        write(into: &output)
        return Data(output)
    }

    /// Upper-bound-ish size guess so large bodies are written without repeated reallocation.
    private var estimatedSize: Int {
        switch self {
        case .null, .bool: return 5
        case .int: return 20
        case .string(let string): return string.utf8.count + 2
        case .array(let items): return items.reduce(2) { $0 + $1.estimatedSize + 1 }
        case .object(let members): return members.reduce(2) { $0 + $1.key.utf8.count + 4 + $1.value.estimatedSize }
        case .base64(let data, let prefix): return prefix.utf8.count + (data.count + 2) / 3 * 4 + 2
        }
    }

    private func write(into output: inout [UInt8]) {
        switch self {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .int(let value):
            output.append(contentsOf: String(value).utf8)
        case .string(let string):
            Self.writeString(string, into: &output)
        case .array(let items):
            output.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                item.write(into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let members):
            output.append(UInt8(ascii: "{"))
            for (index, member) in members.sorted(by: { $0.key < $1.key }).enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                Self.writeString(member.key, into: &output)
                output.append(UInt8(ascii: ":"))
                member.value.write(into: &output)
            }
            output.append(UInt8(ascii: "}"))
        case .base64(let data, let prefix):
            output.append(UInt8(ascii: "\""))
            Self.writeEscapedContents(prefix, into: &output)
            // Base64 output is plain ASCII with no characters that need escaping.
            output.append(contentsOf: data.base64EncodedData())
            output.append(UInt8(ascii: "\""))
        }
    }

    private static func writeString(_ string: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        writeEscapedContents(string, into: &output)
        output.append(UInt8(ascii: "\""))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func writeEscapedContents(_ string: String, into output: inout [UInt8]) {
        let backslash = UInt8(ascii: "\\")
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""):
                output.append(backslash)
                output.append(byte)
            case backslash:
                output.append(backslash)
                output.append(backslash)
            case 0x0A:
                output.append(backslash)
                output.append(UInt8(ascii: "n"))
            case 0x0D:
                output.append(backslash)
                output.append(UInt8(ascii: "r"))
            case 0x09:
                output.append(backslash)
                output.append(UInt8(ascii: "t"))
            case 0x00..<0x20:
                output.append(backslash)
                output.append(contentsOf: "u00".utf8)
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            default:
                output.append(byte)
            }
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Decodes text leniently: a JSON string, a number, or an array of `{"text": …}` parts (joined).
/// Anything else decodes as `nil` instead of failing the enclosing payload — third-party
/// OpenAI-compatible servers are inconsistent about these shapes.
struct LenientText: Decodable, Sendable, Hashable {
    let value: String?

    init(_ value: String?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let parts = try? container.decode([Part].self) {
            let texts = parts.compactMap(\.text)
            value = texts.isEmpty ? nil : texts.joined()
        } else {
            value = nil
        }
    }

    private struct Part: Decodable {
        let text: String?
    }
}

/// Reads only the `type` field of an event payload.
struct EventTypeProbe: Decodable {
    let type: String?
}

extension JSONDecoder {
    /// A decoder for provider payloads (`snake_case` keys).
    static func aiProviderDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension SSEEvent {
    /// The event's type: the SSE `event:` name when the server sent one, otherwise the JSON `type` field.
    func resolvedType(using decoder: JSONDecoder) -> String? {
        if let event, !event.isEmpty, event != "message" { return event }
        return (try? decoder.decode(EventTypeProbe.self, from: Data(data.utf8)))?.type
    }
}
