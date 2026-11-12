import Foundation

/// Structured content a model generates, such as a tool call's arguments, kept as JSON with its
/// keys in the order they were written.
public struct GeneratedContent: Sendable, Equatable, CustomDebugStringConvertible {
    public enum Kind: Sendable, Equatable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([GeneratedContent])
        /// `orderedKeys` holds each key of `properties` once, in the order they were written.
        case structure(properties: [String: GeneratedContent], orderedKeys: [String])
    }

    public let kind: Kind
    public var id: GenerationID?

    public init(kind: Kind, id: GenerationID? = nil) {
        self.kind = kind
        self.id = id
    }

    public init(_ value: some ConvertibleToGeneratedContent) {
        self = value.generatedContent
    }

    public init(_ value: some ConvertibleToGeneratedContent, id: GenerationID) {
        self = value.generatedContent
        self.id = id
    }

    public init(properties: KeyValuePairs<String, any ConvertibleToGeneratedContent>, id: GenerationID? = nil) {
        var values: [String: GeneratedContent] = [:]
        var keys: [String] = []
        for (key, value) in properties {
            if values.updateValue(value.generatedContent, forKey: key) == nil {
                keys.append(key)
            }
        }
        self.init(kind: .structure(properties: values, orderedKeys: keys), id: id)
    }

    public init<S: Sequence>(elements: S, id: GenerationID? = nil) where S.Element == any ConvertibleToGeneratedContent {
        self.init(kind: .array(elements.map(\.generatedContent)), id: id)
    }

    /// - Throws: `LanguageModelSession.GenerationError.decodingFailure` if `json` isn't JSON.
    public init(json: String) throws {
        var parser = JSONParser(Array(json.utf8))
        self = try parser.parseDocument()
    }

    /// Compact, with keys in their order, so that content read from `jsonString` writes the
    /// same string again.
    public var jsonString: String {
        var output = ""
        write(to: &output)
        return output
    }

    public var debugDescription: String { jsonString }

    /// Always `true`: content is only made from whole JSON.
    public var isComplete: Bool { true }

    public func value<Value: ConvertibleFromGeneratedContent>(_ type: Value.Type = Value.self) throws -> Value {
        try Value(self)
    }

    /// - Throws: `LanguageModelSession.GenerationError.decodingFailure` if there's no such property.
    public func value<Value: ConvertibleFromGeneratedContent>(
        _ type: Value.Type = Value.self,
        forProperty property: String
    ) throws -> Value {
        guard case .structure(let properties, _) = kind else {
            throw GenerationErrors.decoding("Expected an object with property \"\(property)\", found \(jsonString)")
        }
        guard let value = properties[property] else {
            throw GenerationErrors.decoding("Missing property \"\(property)\" in \(jsonString)")
        }
        return try Value(value)
    }

    /// `nil` if the property is missing or `null`.
    public func value<Value: ConvertibleFromGeneratedContent>(
        _ type: Value?.Type = Value?.self,
        forProperty property: String
    ) throws -> Value? {
        guard case .structure(let properties, _) = kind else {
            throw GenerationErrors.decoding("Expected an object with property \"\(property)\", found \(jsonString)")
        }
        guard let value = properties[property], value.kind != .null else { return nil }
        return try Value(value)
    }

    /// Ignores ids, which only say where content came from.
    public static func == (lhs: GeneratedContent, rhs: GeneratedContent) -> Bool {
        lhs.kind == rhs.kind
    }
}

/// Identifies content as it's generated.
public struct GenerationID: Sendable, Hashable {
    private let value = UUID()

    public init() {}
}

// MARK: Codable

/// Encodes as its JSON string, which keeps the order of its keys.
extension GeneratedContent: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(json: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonString)
    }
}

// MARK: Writing JSON

extension GeneratedContent {
    func write(to output: inout String) {
        switch kind {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let value):
            output += Self.json(for: value)
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                element.write(to: &output)
            }
            output += "]"
        case .structure(let properties, let keys):
            output += "{"
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                Self.writeString(key, to: &output)
                output += ":"
                (properties[key] ?? GeneratedContent(kind: .null)).write(to: &output)
            }
            output += "}"
        }
    }

    /// Whole numbers without a fraction, as they're usually written.
    static func json(for number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        return String(number)
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count)
                    + String(scalar.value, radix: 16)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: Reading JSON

/// Reads JSON as `GeneratedContent`, keeping the order of each object's keys.
struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> GeneratedContent {
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw failure("Unexpected text after the JSON") }
        return value
    }

    private func failure(_ message: String) -> any Error {
        GenerationErrors.decoding("\(message) at offset \(index) of \(String(decoding: bytes, as: UTF8.self))")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func parseValue(depth: Int) throws -> GeneratedContent {
        guard depth < 512 else { throw failure("JSON nested too deeply") }
        skipWhitespace()
        guard index < bytes.count else { throw failure("Unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth)
        case UInt8(ascii: "\""):
            return GeneratedContent(kind: .string(try parseString()))
        case UInt8(ascii: "t"):
            try expect("true")
            return GeneratedContent(kind: .bool(true))
        case UInt8(ascii: "f"):
            try expect("false")
            return GeneratedContent(kind: .bool(false))
        case UInt8(ascii: "n"):
            try expect("null")
            return GeneratedContent(kind: .null)
        default:
            return GeneratedContent(kind: .number(try parseNumber()))
        }
    }

    private mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure("Expected \(word)")
        }
        index += expected.count
    }

    private mutating func parseObject(depth: Int) throws -> GeneratedContent {
        index += 1
        var properties: [String: GeneratedContent] = [:]
        var keys: [String] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure("Expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure("Expected :") }
            index += 1
            let value = try parseValue(depth: depth + 1)
            if properties.updateValue(value, forKey: key) == nil {
                keys.append(key)
            }
            skipWhitespace()
            guard index < bytes.count else { throw failure("Unexpected end of JSON") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return GeneratedContent(kind: .structure(properties: properties, orderedKeys: keys))
            } else {
                throw failure("Expected , or }")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> GeneratedContent {
        index += 1
        var elements: [GeneratedContent] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return GeneratedContent(kind: .array([]))
        }
        while true {
            elements.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw failure("Unexpected end of JSON") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return GeneratedContent(kind: .array(elements))
            } else {
                throw failure("Expected , or ]")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var run = index
        func flush(_ end: Int) {
            scalars.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                flush(index)
                index += 1
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else {
                guard byte >= 0x20 else { throw failure("Unescaped control character in a string") }
                index += 1
                continue
            }
            flush(index)
            index += 1
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try parseHex()
                if (0xD800..<0xDC00).contains(code) {
                    // The second half of a surrogate pair.
                    if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try parseHex()
                        guard (0xDC00..<0xE000).contains(low) else { throw failure("Invalid surrogate pair") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        throw failure("Invalid surrogate pair")
                    }
                }
                guard let scalar = Unicode.Scalar(code) else { throw failure("Invalid \\u escape") }
                scalars.append(scalar)
            default:
                throw failure("Invalid escape")
            }
            run = index
        }
        throw failure("Unterminated string")
    }

    private mutating func parseHex() throws -> UInt32 {
        guard bytes.count - index >= 4,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw failure("Invalid \\u escape") }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        let digitsStart = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        guard index > digitsStart else { throw failure("Expected a value") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > fractionStart else { throw failure("Expected digits") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            let exponentStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw failure("Expected digits") }
        }
        guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw failure("Invalid number")
        }
        return number
    }
}

/// The errors content conversions throw.
enum GenerationErrors {
    static func decoding(_ description: String) -> LanguageModelSession.GenerationError {
        .decodingFailure(.init(debugDescription: description))
    }
}
