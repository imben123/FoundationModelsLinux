import Foundation

/// The shape of content a model generates, which encodes as JSON Schema.
///
/// Objects are written with `title`, `type`, `properties`, `required`,
/// `additionalProperties: false` and `x-order`, which lists their properties in order.
public struct GenerationSchema: Sendable, Equatable, CustomDebugStringConvertible {
    /// The schema as JSON, with its keys in order.
    let node: GeneratedContent

    init(node: GeneratedContent) {
        self.node = node
    }

    init(primitive type: String) {
        self.init(node: .object([("type", GeneratedContent(type))]))
    }

    init(arrayOf items: GenerationSchema) {
        self.init(node: .object([("type", GeneratedContent("array")), ("items", items.node)]))
    }

    /// A property of an object.
    public struct Property: Sendable {
        let name: String
        let node: GeneratedContent
        let isOptional: Bool

        public init<Value: Generable>(
            name: String,
            description: String? = nil,
            type: Value.Type,
            guides: [GenerationGuide<Value>] = []
        ) {
            self.name = name
            self.node = Self.node(of: Value.generationSchema, description: description, guides: guides)
            self.isOptional = false
        }

        /// A property the model can leave out.
        public init<Value: Generable>(
            name: String,
            description: String? = nil,
            type: Value?.Type,
            guides: [GenerationGuide<Value>] = []
        ) {
            self.name = name
            self.node = Self.node(of: Value.generationSchema, description: description, guides: guides)
            self.isOptional = true
        }

        private static func node<Value>(
            of schema: GenerationSchema,
            description: String?,
            guides: [GenerationGuide<Value>]
        ) -> GeneratedContent {
            var node = schema.node
            if let description {
                node = node.prepending("description", GeneratedContent(description))
            }
            for keyword in guides.flatMap(\.keywords) {
                node = node.setting(keyword.0, keyword.1)
            }
            return node
        }
    }

    /// An object with `properties`, in order.
    public init(type: any Generable.Type, description: String? = nil, properties: [Property]) {
        var keys: [(String, GeneratedContent)] = [("title", GeneratedContent(Self.title(of: type)))]
        if let description {
            keys.append(("description", GeneratedContent(description)))
        }
        keys += [
            ("type", GeneratedContent("object")),
            ("properties", .object(properties.map { ($0.name, $0.node) })),
            ("required", GeneratedContent(properties.filter { !$0.isOptional }.map(\.name))),
            ("additionalProperties", GeneratedContent(false)),
            ("x-order", GeneratedContent(properties.map(\.name))),
        ]
        self.init(node: .object(keys))
    }

    /// One of `choices`, as for an enum without associated values.
    public init(type: any Generable.Type, description: String? = nil, anyOf choices: [String]) {
        var keys: [(String, GeneratedContent)] = [("title", GeneratedContent(Self.title(of: type)))]
        if let description {
            keys.append(("description", GeneratedContent(description)))
        }
        keys += [("type", GeneratedContent("string")), ("enum", GeneratedContent(choices))]
        self.init(node: .object(keys))
    }

    /// Content of any of `types`.
    public init(type: any Generable.Type, description: String? = nil, anyOf types: [any Generable.Type]) {
        var keys: [(String, GeneratedContent)] = [("title", GeneratedContent(Self.title(of: type)))]
        if let description {
            keys.append(("description", GeneratedContent(description)))
        }
        keys.append(("anyOf", GeneratedContent(kind: .array(types.map { $0.generationSchema.node }))))
        self.init(node: .object(keys))
    }

    private static func title(of type: any Generable.Type) -> String {
        String(describing: type)
    }

    public var debugDescription: String { node.jsonString }
}

// MARK: Codable

/// Encodes as JSON Schema, not as a string.
extension GenerationSchema: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(node: try JSONNode(from: decoder).content)
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONNode(content: node).encode(to: encoder)
    }
}

/// Codes `GeneratedContent` as the JSON it holds. Decoding loses the order of keys.
struct JSONNode: Codable {
    let content: GeneratedContent

    init(content: GeneratedContent) {
        self.content = content
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch content.kind {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            if let integer = Int(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let elements):
            var container = encoder.unkeyedContainer()
            for element in elements {
                try container.encode(JSONNode(content: element))
            }
        case .structure(let properties, let keys):
            var container = encoder.container(keyedBy: Key.self)
            for key in keys {
                try container.encode(JSONNode(content: properties[key] ?? GeneratedContent(kind: .null)), forKey: Key(stringValue: key))
            }
        }
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: Key.self) {
            var properties: [String: GeneratedContent] = [:]
            let keys = container.allKeys.map(\.stringValue).sorted()
            for key in keys {
                properties[key] = try container.decode(JSONNode.self, forKey: Key(stringValue: key)).content
            }
            content = GeneratedContent(kind: .structure(properties: properties, orderedKeys: keys))
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var elements: [GeneratedContent] = []
            while !container.isAtEnd {
                elements.append(try container.decode(JSONNode.self).content)
            }
            content = GeneratedContent(kind: .array(elements))
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            content = GeneratedContent(kind: .null)
        } else if let value = try? container.decode(Bool.self) {
            content = GeneratedContent(kind: .bool(value))
        } else if let value = try? container.decode(Double.self) {
            content = GeneratedContent(kind: .number(value))
        } else {
            content = GeneratedContent(kind: .string(try container.decode(String.self)))
        }
    }
}

// MARK: Building JSON

extension GeneratedContent {
    /// An object with `keys` in order.
    static func object(_ keys: [(String, GeneratedContent)]) -> GeneratedContent {
        var properties: [String: GeneratedContent] = [:]
        var order: [String] = []
        for (key, value) in keys {
            if properties.updateValue(value, forKey: key) == nil {
                order.append(key)
            }
        }
        return GeneratedContent(kind: .structure(properties: properties, orderedKeys: order))
    }

    /// This object with `key` set to `value`, keeping its place if it was there.
    func setting(_ key: String, _ value: GeneratedContent) -> GeneratedContent {
        guard case .structure(var properties, var keys) = kind else { return self }
        if properties.updateValue(value, forKey: key) == nil {
            keys.append(key)
        }
        return GeneratedContent(kind: .structure(properties: properties, orderedKeys: keys))
    }

    /// This object with `key` set to `value`, first.
    func prepending(_ key: String, _ value: GeneratedContent) -> GeneratedContent {
        guard case .structure(var properties, var keys) = kind else { return self }
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        properties[key] = value
        return GeneratedContent(kind: .structure(properties: properties, orderedKeys: keys))
    }
}
