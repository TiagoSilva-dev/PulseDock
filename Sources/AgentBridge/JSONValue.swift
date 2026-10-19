import Foundation

/// A Codable representation of arbitrary JSON, used for sanitized hook payloads.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Integral values are written as integers (`5`, not `5.0`): JSON-RPC ids must
            // round-trip exactly to strict decoders.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Converts the output of `JSONSerialization` into a `JSONValue`.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: value!))
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(dictionary) = self { return dictionary[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(value)) : String(value)
        case let .bool(value): value ? "true" : "false"
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .number(value): Int(exactly: value.rounded()) ?? Int(value)
        case let .string(value): Int(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .string(value): value == "true" ? true : (value == "false" ? false : nil)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Canonical (sorted-keys) JSON text, used for fingerprints.
    public var canonicalString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
