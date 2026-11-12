import Foundation

/// A type that can be made from content a model generated.
public protocol ConvertibleFromGeneratedContent: SendableMetatype {
    init(_ content: GeneratedContent) throws
}

/// A type that can be given to a model as content.
public protocol ConvertibleToGeneratedContent: InstructionsRepresentable, PromptRepresentable {
    var generatedContent: GeneratedContent { get }
}

extension ConvertibleToGeneratedContent {
    public var promptRepresentation: Prompt { Prompt(generatedContent.jsonString) }
    public var instructionsRepresentation: Instructions { Instructions(generatedContent.jsonString) }
}

/// A type a model can generate, following its ``generationSchema``.
public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent, Sendable {
    /// What a stream gives while the content is being written. Only whole content is given here.
    associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent, Sendable = Self
    static var generationSchema: GenerationSchema { get }
}

/// Makes a struct or an enum without associated values ``Generable``.
///
/// For a struct, every stored property is generated, except a `let` with a value. Describe
/// each one with ``Guide(description:)``.
@attached(
    extension,
    conformances: Generable,
    names: named(init(_:)), named(generatedContent), named(generationSchema)
)
public macro Generable(description: String? = nil) = #externalMacro(module: "FoundationModelsMacros", type: "GenerableMacro")

/// Describes a property of a ``Generable(description:)`` type to the model.
@attached(peer)
public macro Guide(description: String) = #externalMacro(module: "FoundationModelsMacros", type: "GuideMacro")

/// Describes a property of a ``Generable(description:)`` type to the model, and limits its values.
@attached(peer)
public macro Guide<T>(description: String? = nil, _ guides: GenerationGuide<T>...) = #externalMacro(module: "FoundationModelsMacros", type: "GuideMacro")

// MARK: Guides

/// A limit on the values a model can generate for a property.
public struct GenerationGuide<Value>: Sendable {
    /// The JSON Schema keys this guide sets.
    let keywords: [(String, GeneratedContent)]

    init(_ keywords: [(String, GeneratedContent)]) {
        self.keywords = keywords
    }
}

extension GenerationGuide where Value == String {
    public static func constant(_ value: String) -> GenerationGuide<String> {
        GenerationGuide([("enum", GeneratedContent(elements: [value]))])
    }

    public static func anyOf(_ values: [String]) -> GenerationGuide<String> {
        GenerationGuide([("enum", GeneratedContent(elements: values.map { $0 as any ConvertibleToGeneratedContent }))])
    }

    /// A regular expression, in the syntax JSON Schema uses.
    public static func pattern(_ pattern: String) -> GenerationGuide<String> {
        GenerationGuide([("pattern", GeneratedContent(pattern))])
    }
}

extension GenerationGuide where Value == Int {
    public static func minimum(_ value: Int) -> GenerationGuide<Int> {
        GenerationGuide([("minimum", GeneratedContent(value))])
    }

    public static func maximum(_ value: Int) -> GenerationGuide<Int> {
        GenerationGuide([("maximum", GeneratedContent(value))])
    }

    public static func range(_ range: ClosedRange<Int>) -> GenerationGuide<Int> {
        GenerationGuide([("minimum", GeneratedContent(range.lowerBound)), ("maximum", GeneratedContent(range.upperBound))])
    }
}

extension GenerationGuide where Value == Double {
    public static func minimum(_ value: Double) -> GenerationGuide<Double> {
        GenerationGuide([("minimum", GeneratedContent(value))])
    }

    public static func maximum(_ value: Double) -> GenerationGuide<Double> {
        GenerationGuide([("maximum", GeneratedContent(value))])
    }

    public static func range(_ range: ClosedRange<Double>) -> GenerationGuide<Double> {
        GenerationGuide([("minimum", GeneratedContent(range.lowerBound)), ("maximum", GeneratedContent(range.upperBound))])
    }
}

extension GenerationGuide {
    public static func minimumCount<Element>(_ count: Int) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([("minItems", GeneratedContent(count))])
    }

    public static func maximumCount<Element>(_ count: Int) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([("maxItems", GeneratedContent(count))])
    }

    public static func count<Element>(_ count: Int) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([("minItems", GeneratedContent(count)), ("maxItems", GeneratedContent(count))])
    }

    public static func count<Element>(_ range: ClosedRange<Int>) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([
            ("minItems", GeneratedContent(range.lowerBound)),
            ("maxItems", GeneratedContent(range.upperBound)),
        ])
    }
}

// MARK: Standard types

extension String: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema(primitive: "string") }

    public init(_ content: GeneratedContent) throws {
        guard case .string(let value) = content.kind else {
            throw GenerationErrors.decoding("Expected a string, found \(content.jsonString)")
        }
        self = value
    }

    public var generatedContent: GeneratedContent { GeneratedContent(kind: .string(self)) }
    public var promptRepresentation: Prompt { Prompt(self) }
    public var instructionsRepresentation: Instructions { Instructions(self) }
}

extension Bool: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema(primitive: "boolean") }

    public init(_ content: GeneratedContent) throws {
        guard case .bool(let value) = content.kind else {
            throw GenerationErrors.decoding("Expected a Boolean, found \(content.jsonString)")
        }
        self = value
    }

    public var generatedContent: GeneratedContent { GeneratedContent(kind: .bool(self)) }
}

extension Int: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema(primitive: "integer") }

    public init(_ content: GeneratedContent) throws {
        guard case .number(let value) = content.kind, let integer = Int(exactly: value) else {
            throw GenerationErrors.decoding("Expected an integer, found \(content.jsonString)")
        }
        self = integer
    }

    public var generatedContent: GeneratedContent { GeneratedContent(kind: .number(Double(self))) }
}

extension Double: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema(primitive: "number") }

    public init(_ content: GeneratedContent) throws {
        guard case .number(let value) = content.kind else {
            throw GenerationErrors.decoding("Expected a number, found \(content.jsonString)")
        }
        self = value
    }

    public var generatedContent: GeneratedContent { GeneratedContent(kind: .number(self)) }
}

extension Float: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema(primitive: "number") }

    public init(_ content: GeneratedContent) throws {
        self = Float(try Double(content))
    }

    public var generatedContent: GeneratedContent { GeneratedContent(kind: .number(Double(self))) }
}

extension Decimal: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema(primitive: "number") }

    public init(_ content: GeneratedContent) throws {
        self = Decimal(try Double(content))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(kind: .number(NSDecimalNumber(decimal: self).doubleValue))
    }
}

extension Array: Generable where Element: Generable {
    public typealias PartiallyGenerated = [Element]

    public static var generationSchema: GenerationSchema {
        GenerationSchema(arrayOf: Element.generationSchema)
    }
}

extension Array: ConvertibleFromGeneratedContent where Element: ConvertibleFromGeneratedContent {
    public init(_ content: GeneratedContent) throws {
        guard case .array(let elements) = content.kind else {
            throw GenerationErrors.decoding("Expected an array, found \(content.jsonString)")
        }
        self = try elements.map(Element.init)
    }
}

extension Array: PromptRepresentable where Element: ConvertibleToGeneratedContent {}
extension Array: InstructionsRepresentable where Element: ConvertibleToGeneratedContent {}
extension Array: ConvertibleToGeneratedContent where Element: ConvertibleToGeneratedContent {
    public var generatedContent: GeneratedContent {
        GeneratedContent(kind: .array(map(\.generatedContent)))
    }
}

extension Optional: PromptRepresentable where Wrapped: ConvertibleToGeneratedContent {}
extension Optional: InstructionsRepresentable where Wrapped: ConvertibleToGeneratedContent {}
extension Optional: ConvertibleToGeneratedContent where Wrapped: ConvertibleToGeneratedContent {
    public var generatedContent: GeneratedContent {
        self?.generatedContent ?? GeneratedContent(kind: .null)
    }
}

extension GeneratedContent: Generable {
    /// Any JSON.
    public static var generationSchema: GenerationSchema { GenerationSchema(node: GeneratedContent(properties: [:])) }

    public init(_ content: GeneratedContent) throws {
        self = content
    }

    public var generatedContent: GeneratedContent { self }
}
