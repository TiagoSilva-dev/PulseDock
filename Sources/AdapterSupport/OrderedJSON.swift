import Foundation

/// JSON value that preserves object key order, so PulseDock can edit agent configuration
/// files surgically (only the `hooks` section changes) without reordering the user's keys.
public indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// Numbers keep their original literal so values round-trip exactly.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b || Double(a) == Double(b)
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    // MARK: Access

    public subscript(key: String) -> OrderedJSON? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var objectPairs: [(String, OrderedJSON)]? {
        if case let .object(pairs) = self { return pairs }
        return nil
    }

    public var arrayValue: [OrderedJSON]? {
        if case let .array(values) = self { return values }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Returns a copy with `key` set (replacing in place, or appended at the end).
    public func setting(_ key: String, to value: OrderedJSON) -> OrderedJSON {
        guard case var .object(pairs) = self else { return .object([(key, value)]) }
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[index].1 = value
        } else {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    public func removing(_ key: String) -> OrderedJSON {
        guard case let .object(pairs) = self else { return self }
        return .object(pairs.filter { $0.0 != key })
    }

    // MARK: Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unexpectedEnd
        case unexpectedCharacter(Character, offset: Int)
        case invalidLiteral(offset: Int)
        case trailingContent(offset: Int)

        public var description: String {
            switch self {
            case .unexpectedEnd: "unexpected end of JSON"
            case let .unexpectedCharacter(character, offset): "unexpected '\(character)' at \(offset)"
            case let .invalidLiteral(offset): "invalid literal at \(offset)"
            case let .trailingContent(offset): "unexpected content after JSON at \(offset)"
            }
        }
    }

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.scalars.count else { throw ParseError.trailingContent(offset: parser.index) }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipWhitespace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func parseValue() throws -> OrderedJSON {
            guard index < scalars.count else { throw ParseError.unexpectedEnd }
            switch scalars[index] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw ParseError.invalidLiteral(offset: index) }
                index += 1
            }
        }

        mutating func parseObject() throws -> OrderedJSON {
            index += 1
            var pairs: [(String, OrderedJSON)] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < scalars.count else { throw ParseError.unexpectedEnd }
                guard scalars[index] == "\"" else { throw ParseError.unexpectedCharacter(Character(scalars[index]), offset: index) }
                let key = try parseString()
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { throw ParseError.unexpectedEnd }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                pairs.append((key, value))
                skipWhitespace()
                guard index < scalars.count else { throw ParseError.unexpectedEnd }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(pairs) }
                throw ParseError.unexpectedCharacter(Character(scalars[index]), offset: index)
            }
        }

        mutating func parseArray() throws -> OrderedJSON {
            index += 1
            var values: [OrderedJSON] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" { index += 1; return .array(values) }
            while true {
                skipWhitespace()
                values.append(try parseValue())
                skipWhitespace()
                guard index < scalars.count else { throw ParseError.unexpectedEnd }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(values) }
                throw ParseError.unexpectedCharacter(Character(scalars[index]), offset: index)
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    guard index < scalars.count else { throw ParseError.unexpectedEnd }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u":
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                            index += 2
                            let low = try parseHex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default:
                        throw ParseError.unexpectedCharacter(Character(escape), offset: index - 1)
                    }
                default:
                    result.append(scalar)
                }
            }
            throw ParseError.unexpectedEnd
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw ParseError.unexpectedEnd }
            let text = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            index += 4
            guard let value = UInt32(text, radix: 16) else { throw ParseError.invalidLiteral(offset: index - 4) }
            return value
        }

        mutating func parseNumber() throws -> OrderedJSON {
            let start = index
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            guard index > start else { throw ParseError.unexpectedCharacter(Character(scalars[start]), offset: start) }
            let literal = String(String.UnicodeScalarView(scalars[start..<index]))
            guard Double(literal) != nil else { throw ParseError.invalidLiteral(offset: start) }
            return .number(literal)
        }
    }

    // MARK: Serialization

    /// Serializes with two-space indentation (the style Claude Code uses for settings files).
    public func serialized(indent: Int = 2) -> String {
        var output = ""
        write(into: &output, level: 0, indent: indent)
        return output + "\n"
    }

    private func write(into output: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let closingPad = String(repeating: " ", count: level * indent)
        switch self {
        case .null: output += "null"
        case let .bool(value): output += value ? "true" : "false"
        case let .number(literal): output += literal
        case let .string(value): output += OrderedJSON.quote(value)
        case let .array(values):
            if values.isEmpty { output += "[]"; return }
            output += "[\n"
            for (offset, value) in values.enumerated() {
                output += pad
                value.write(into: &output, level: level + 1, indent: indent)
                output += offset == values.count - 1 ? "\n" : ",\n"
            }
            output += closingPad + "]"
        case let .object(pairs):
            if pairs.isEmpty { output += "{}"; return }
            output += "{\n"
            for (offset, pair) in pairs.enumerated() {
                output += pad + OrderedJSON.quote(pair.0) + ": "
                pair.1.write(into: &output, level: level + 1, indent: indent)
                output += offset == pairs.count - 1 ? "\n" : ",\n"
            }
            output += closingPad + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
