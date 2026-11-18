import Foundation

/// What a model is asked.
public struct Prompt: Sendable, PromptRepresentable {
    enum Part: Sendable {
        case text(String)
        case attachment(Transcript.AttachmentSegment)
    }

    let parts: [Part]

    public init(_ content: some PromptRepresentable) {
        self.parts = content.promptRepresentation.parts
    }

    public init(@PromptBuilder _ content: () throws -> Prompt) rethrows {
        self = try content()
    }

    init(parts: [Part]) {
        self.parts = parts
    }

    init(_ text: String) {
        self.parts = [.text(text)]
    }

    public var promptRepresentation: Prompt { self }

    /// The prompt's segments: each attachment, and each run of text between them as one segment,
    /// with its parts on lines of their own.
    var segments: [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var text: [String] = []
        func endText() {
            if !text.isEmpty {
                segments.append(.text(Transcript.TextSegment(content: text.joined(separator: "\n"))))
                text = []
            }
        }
        for part in parts {
            switch part {
            case .text(let part): text.append(part)
            case .attachment(let attachment):
                endText()
                segments.append(.attachment(attachment))
            }
        }
        endText()
        return segments.isEmpty ? [.text(Transcript.TextSegment(content: ""))] : segments
    }
}

/// A type that can be part of a ``Prompt``.
public protocol PromptRepresentable {
    @PromptBuilder var promptRepresentation: Prompt { get }
}

@resultBuilder
public struct PromptBuilder {
    public static func buildExpression(_ expression: some PromptRepresentable) -> Prompt {
        expression.promptRepresentation
    }

    /// A prompt as it is. Without this, a prompt's own `promptRepresentation`, which the protocol makes a
    /// builder, would call itself.
    public static func buildExpression(_ expression: Prompt) -> Prompt {
        expression
    }

    public static func buildBlock(_ components: Prompt...) -> Prompt {
        Prompt(parts: components.flatMap(\.parts))
    }

    public static func buildArray(_ components: [Prompt]) -> Prompt {
        Prompt(parts: components.flatMap(\.parts))
    }

    public static func buildOptional(_ component: Prompt?) -> Prompt {
        component ?? Prompt(parts: [])
    }

    public static func buildEither(first component: Prompt) -> Prompt {
        component
    }

    public static func buildEither(second component: Prompt) -> Prompt {
        component
    }

    public static func buildLimitedAvailability(_ component: Prompt) -> Prompt {
        component
    }
}

/// What a model is told to do in every reply of a session.
public struct Instructions: Sendable, InstructionsRepresentable {
    let parts: [String]

    public init(_ content: some InstructionsRepresentable) {
        self.parts = content.instructionsRepresentation.parts
    }

    public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows {
        self = try content()
    }

    init(parts: [String]) {
        self.parts = parts
    }

    init(_ text: String) {
        self.parts = [text]
    }

    public var instructionsRepresentation: Instructions { self }

    var text: String { parts.joined(separator: "\n") }
}

/// A type that can be part of ``Instructions``.
public protocol InstructionsRepresentable {
    @InstructionsBuilder var instructionsRepresentation: Instructions { get }
}

@resultBuilder
public struct InstructionsBuilder {
    public static func buildExpression(_ expression: some InstructionsRepresentable) -> Instructions {
        expression.instructionsRepresentation
    }

    /// A instructions as it is. Without this, a instructions's own `instructionsRepresentation`, which the protocol makes a
    /// builder, would call itself.
    public static func buildExpression(_ expression: Instructions) -> Instructions {
        expression
    }

    public static func buildBlock(_ components: Instructions...) -> Instructions {
        Instructions(parts: components.flatMap(\.parts))
    }

    public static func buildArray(_ components: [Instructions]) -> Instructions {
        Instructions(parts: components.flatMap(\.parts))
    }

    public static func buildOptional(_ component: Instructions?) -> Instructions {
        component ?? Instructions(parts: [])
    }

    public static func buildEither(first component: Instructions) -> Instructions {
        component
    }

    public static func buildEither(second component: Instructions) -> Instructions {
        component
    }

    public static func buildLimitedAvailability(_ component: Instructions) -> Instructions {
        component
    }
}

/// How a model generates a reply. A model may not support every option.
public struct GenerationOptions: Sendable, Equatable, Codable {
    public struct SamplingMode: Sendable, Equatable, Codable {
        public enum Kind: Sendable, Equatable, Codable {
            case greedy
            case randomTopK(_ k: Int, seed: UInt64?)
            case randomProbabilityThreshold(_ threshold: Double, seed: UInt64?)
        }

        public let kind: Kind

        /// Always the likeliest token.
        public static var greedy: SamplingMode { SamplingMode(kind: .greedy) }

        public static func random(top k: Int, seed: UInt64? = nil) -> SamplingMode {
            SamplingMode(kind: .randomTopK(k, seed: seed))
        }

        public static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> SamplingMode {
            SamplingMode(kind: .randomProbabilityThreshold(probabilityThreshold, seed: seed))
        }
    }

    /// Whether the model may, must or mustn't call a tool.
    public struct ToolCallingMode: Sendable, Equatable, Codable {
        public enum Kind: Sendable, Equatable, Hashable, Codable {
            case allowed
            case required
            case disallowed
        }

        public var kind: Kind

        public static let allowed = ToolCallingMode(kind: .allowed)
        public static let required = ToolCallingMode(kind: .required)
        public static let disallowed = ToolCallingMode(kind: .disallowed)
    }

    public var samplingMode: SamplingMode?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var toolCallingMode: ToolCallingMode?

    @available(*, deprecated, renamed: "samplingMode")
    public var sampling: SamplingMode? {
        get { samplingMode }
        set { samplingMode = newValue }
    }

    public init(samplingMode: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.samplingMode = samplingMode
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }

    public init(samplingMode: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil, toolCallingMode: ToolCallingMode?) {
        self.init(samplingMode: samplingMode, temperature: temperature, maximumResponseTokens: maximumResponseTokens)
        self.toolCallingMode = toolCallingMode
    }

    @available(*, deprecated, renamed: "init(samplingMode:temperature:maximumResponseTokens:)")
    public init(sampling: SamplingMode?, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.init(samplingMode: sampling, temperature: temperature, maximumResponseTokens: maximumResponseTokens)
    }
}

/// How a model treats the context it's given.
public struct ContextOptions: Sendable, Equatable {
    /// How much a model that reasons should.
    public enum ReasoningLevel: Sendable, Equatable {
        case light
        case moderate
        case deep
        case custom(String)
    }

    public var includeSchemaInPrompt: Bool?
    public var reasoningLevel: ReasoningLevel?

    public init(includeSchemaInPrompt: Bool? = nil, reasoningLevel: ReasoningLevel? = nil) {
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.reasoningLevel = reasoningLevel
    }
}
