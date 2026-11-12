import Foundation

/// Everything in a session, in order: its instructions, prompts, the model's reasoning and
/// responses, and the tool calls it made with their output.
public struct Transcript: Sendable, Equatable, Codable, RandomAccessCollection, CustomStringConvertible {
    private var entries: [Entry]

    public init(entries: some Sequence<Entry> = []) {
        self.entries = Array(entries)
    }

    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }

    public subscript(position: Int) -> Entry {
        entries[position]
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
    }

    mutating func update(at index: Int, _ change: (inout Entry) -> Void) {
        change(&entries[index])
    }

    public var description: String {
        entries.map(\.description).joined(separator: "\n")
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var entries: [Entry] = []
        while !container.isAtEnd {
            entries.append(try container.decode(Entry.self))
        }
        self.entries = entries
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for entry in entries {
            try container.encode(entry)
        }
    }

    // MARK: Entries

    public enum Entry: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        case instructions(Instructions)
        case prompt(Prompt)
        case toolCalls(ToolCalls)
        case toolOutput(ToolOutput)
        case response(Response)
        case reasoning(Reasoning)

        public var id: String {
            switch self {
            case .instructions(let entry): entry.id
            case .prompt(let entry): entry.id
            case .toolCalls(let entry): entry.id
            case .toolOutput(let entry): entry.id
            case .response(let entry): entry.id
            case .reasoning(let entry): entry.id
            }
        }

        public var description: String {
            switch self {
            case .instructions(let entry): entry.description
            case .prompt(let entry): entry.description
            case .toolCalls(let entry): entry.description
            case .toolOutput(let entry): entry.description
            case .response(let entry): entry.description
            case .reasoning(let entry): entry.description
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, instructions, prompt, toolCalls, toolOutput, response, reasoning
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "instructions": self = .instructions(try container.decode(Instructions.self, forKey: .instructions))
            case "prompt": self = .prompt(try container.decode(Prompt.self, forKey: .prompt))
            case "toolCalls": self = .toolCalls(try container.decode(ToolCalls.self, forKey: .toolCalls))
            case "toolOutput": self = .toolOutput(try container.decode(ToolOutput.self, forKey: .toolOutput))
            case "response": self = .response(try container.decode(Response.self, forKey: .response))
            case "reasoning": self = .reasoning(try container.decode(Reasoning.self, forKey: .reasoning))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown entry \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .instructions(let entry):
                try container.encode("instructions", forKey: .type)
                try container.encode(entry, forKey: .instructions)
            case .prompt(let entry):
                try container.encode("prompt", forKey: .type)
                try container.encode(entry, forKey: .prompt)
            case .toolCalls(let entry):
                try container.encode("toolCalls", forKey: .type)
                try container.encode(entry, forKey: .toolCalls)
            case .toolOutput(let entry):
                try container.encode("toolOutput", forKey: .type)
                try container.encode(entry, forKey: .toolOutput)
            case .response(let entry):
                try container.encode("response", forKey: .type)
                try container.encode(entry, forKey: .response)
            case .reasoning(let entry):
                try container.encode("reasoning", forKey: .type)
                try container.encode(entry, forKey: .reasoning)
            }
        }
    }

    // MARK: Segments

    public enum Segment: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        case text(TextSegment)
        case structure(StructuredSegment)

        public var id: String {
            switch self {
            case .text(let segment): segment.id
            case .structure(let segment): segment.id
            }
        }

        /// The segment's text, as it is.
        public var description: String {
            switch self {
            case .text(let segment): segment.description
            case .structure(let segment): segment.description
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, structure
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text": self = .text(try container.decode(TextSegment.self, forKey: .text))
            case "structure": self = .structure(try container.decode(StructuredSegment.self, forKey: .structure))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown segment \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let segment):
                try container.encode("text", forKey: .type)
                try container.encode(segment, forKey: .text)
            case .structure(let segment):
                try container.encode("structure", forKey: .type)
                try container.encode(segment, forKey: .structure)
            }
        }
    }

    public struct TextSegment: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var content: String

        public init(id: String = UUID().uuidString, content: String) {
            self.id = id
            self.content = content
        }

        public var description: String { content }
    }

    public struct StructuredSegment: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        /// Where the content came from, such as a tool's name.
        public var source: String
        public var content: GeneratedContent

        public init(id: String = UUID().uuidString, source: String, content: GeneratedContent) {
            self.id = id
            self.source = source
            self.content = content
        }

        public var description: String { content.jsonString }
    }

    // MARK: Entry types

    public struct Instructions: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var segments: [Segment]
        public var toolDefinitions: [ToolDefinition]

        public init(id: String = UUID().uuidString, segments: [Segment], toolDefinitions: [ToolDefinition]) {
            self.id = id
            self.segments = segments
            self.toolDefinitions = toolDefinitions
        }

        public var description: String {
            let tools = toolDefinitions.map { "\($0.name): \($0.description)" }
            return (["Instructions: " + segments.text] + tools).joined(separator: "\n")
        }
    }

    public struct ToolDefinition: Sendable, Equatable, Codable {
        public var name: String
        public var description: String
        /// The schema of the tool's arguments.
        public var parameters: GenerationSchema

        public init(name: String, description: String, parameters: GenerationSchema) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }

        public init(tool: some Tool) {
            self.init(name: tool.name, description: tool.description, parameters: tool.parameters)
        }
    }

    public struct Prompt: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var segments: [Segment]
        public var options: GenerationOptions
        public var responseFormat: ResponseFormat?

        public init(
            id: String = UUID().uuidString,
            segments: [Segment],
            options: GenerationOptions = GenerationOptions(),
            responseFormat: ResponseFormat? = nil
        ) {
            self.id = id
            self.segments = segments
            self.options = options
            self.responseFormat = responseFormat
        }

        public var description: String { "Prompt: " + segments.text }
    }

    /// The schema a prompt asked the response to follow.
    public struct ResponseFormat: Sendable, Equatable, Codable {
        public var name: String
        var schema: GenerationSchema

        public init(type: (some Generable).Type) {
            self.name = String(describing: type)
            self.schema = type.generationSchema
        }

        public init(schema: GenerationSchema) {
            self.name = "schema"
            self.schema = schema
        }
    }

    public struct ToolCalls: Sendable, Equatable, Identifiable, Codable, RandomAccessCollection, CustomStringConvertible {
        public var id: String
        private var calls: [ToolCall]

        public init(id: String = UUID().uuidString, _ calls: some Sequence<ToolCall>) {
            self.id = id
            self.calls = Array(calls)
        }

        public var startIndex: Int { calls.startIndex }
        public var endIndex: Int { calls.endIndex }

        public subscript(position: Int) -> ToolCall {
            calls[position]
        }

        public var description: String {
            "Tool calls: " + calls.map(\.description).joined(separator: ", ")
        }
    }

    public struct ToolCall: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var toolName: String
        public var arguments: GeneratedContent
        /// What the model's provider keeps with the call.
        public var metadata: [String: GeneratedContent]

        public init(id: String, toolName: String, arguments: GeneratedContent) {
            self.init(id: id, metadata: [:], toolName: toolName, arguments: arguments)
        }

        public init(id: String, metadata: [String: any ConvertibleToGeneratedContent], toolName: String, arguments: GeneratedContent) {
            self.id = id
            self.toolName = toolName
            self.arguments = arguments
            self.metadata = metadata.mapValues(\.generatedContent)
        }

        public var description: String { "\(toolName)(\(arguments.jsonString))" }
    }

    public struct ToolOutput: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        /// The ID of the call this answers.
        public var id: String
        public var toolName: String
        public var segments: [Segment]

        public init(id: String, toolName: String, segments: [Segment]) {
            self.id = id
            self.toolName = toolName
            self.segments = segments
        }

        public var description: String { "Output of \(toolName): " + segments.text }
    }

    public struct Response: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var assetIDs: [String]
        public var segments: [Segment]
        /// What the model's provider keeps with the response.
        public var metadata: [String: GeneratedContent]

        public init(id: String = UUID().uuidString, assetIDs: [String], segments: [Segment]) {
            self.id = id
            self.assetIDs = assetIDs
            self.segments = segments
            self.metadata = [:]
        }

        public init(id: String = UUID().uuidString, metadata: [String: any ConvertibleToGeneratedContent] = [:], segments: [Segment]) {
            self.init(id: id, assetIDs: [], segments: segments)
            self.metadata = metadata.mapValues(\.generatedContent)
        }

        public var description: String { "Response: " + segments.text }
    }

    /// What the model reasoned before it responded or called a tool.
    public struct Reasoning: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var segments: [Segment]
        /// Proves to the model's provider that it wrote the reasoning, for a provider that needs it back.
        public var signature: Data?
        /// What the model's provider keeps with the reasoning.
        public var metadata: [String: GeneratedContent]

        public init(
            id: String = UUID().uuidString,
            metadata: [String: any ConvertibleToGeneratedContent] = [:],
            segments: [Segment],
            signature: Data? = nil
        ) {
            self.id = id
            self.segments = segments
            self.signature = signature
            self.metadata = metadata.mapValues(\.generatedContent)
        }

        public var description: String { "Reasoning: " + segments.text }
    }
}

extension [Transcript.Segment] {
    /// Each segment's text, joined.
    var text: String {
        map(\.description).joined()
    }
}
