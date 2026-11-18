import Foundation

/// A model a ``LanguageModelSession`` can use, which its ``Executor`` runs.
public protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Executor.Model == Self

    /// What the model can do, which sessions follow.
    var capabilities: LanguageModelCapabilities { get }
    /// Sessions share an executor for each configuration.
    var executorConfiguration: Executor.Configuration { get }
    /// Whether the model reads data attachments of `type`, which a session checks before it
    /// sends one. None, unless the model says so.
    func supportsDataAttachmentType(_ type: UTType) async throws -> Bool
}

extension LanguageModel {
    public func supportsDataAttachmentType(_ type: UTType) async throws -> Bool { false }
}

/// What a model can do.
public struct LanguageModelCapabilities: Sendable {
    private let capabilities: Set<Capability>

    public init(_ capabilities: [Capability]) {
        self.capabilities = Set(capabilities)
    }

    public func contains(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    public struct Capability: Sendable, Hashable {
        private let name: String

        /// The model can read images.
        public static var vision: Capability { Capability(name: "vision") }
        /// The model can follow a schema.
        public static var guidedGeneration: Capability { Capability(name: "guidedGeneration") }
        /// The model reasons before it responds.
        public static var reasoning: Capability { Capability(name: "reasoning") }
        /// The model can call a session's tools.
        public static var toolCalling: Capability { Capability(name: "toolCalling") }
    }
}

/// Runs requests for a ``LanguageModel``.
public protocol LanguageModelExecutor: Sendable {
    associatedtype Model: LanguageModel
    associatedtype Configuration: Hashable & Sendable

    init(configuration: Configuration) throws

    /// Gets ready for a request that will continue `transcript`.
    func prewarm(model: Model, transcript: Transcript)

    /// Generates the next part of `request`'s transcript, sending it into `channel` as it's written.
    ///
    /// A request ends with the model's response, or with tool calls, which the session runs
    /// before it makes the next request.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws
}

extension LanguageModelExecutor {
    public func prewarm(model: Model, transcript: Transcript) {}
}

/// What a session asks a model for.
public struct LanguageModelExecutorGenerationRequest: Sendable {
    public var id: UUID
    /// Everything so far, ending with the prompt or the output of tool calls.
    public var transcript: Transcript
    /// The tools the model can call.
    public var enabledToolDefinitions: [Transcript.ToolDefinition]
    /// The schema the response has to follow, if there is one.
    public var schema: GenerationSchema?
    public var generationOptions: GenerationOptions
    public var contextOptions: ContextOptions
    public var metadata: [String: GeneratedContent]

    public init(
        id: UUID,
        transcript: Transcript,
        enabledTools: [Transcript.ToolDefinition],
        schema: GenerationSchema? = nil,
        generationOptions: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any ConvertibleToGeneratedContent]
    ) {
        self.id = id
        self.transcript = transcript
        self.enabledToolDefinitions = enabledTools
        self.schema = schema
        self.generationOptions = generationOptions
        self.contextOptions = contextOptions
        self.metadata = metadata.mapValues(\.generatedContent)
    }
}

/// Where an executor sends what a model generates, as it's generated.
///
/// An event can name the transcript entry it adds to with an `entryID`. The session starts an
/// entry with that ID the first time text, a signature, metadata or a tool call names it, and
/// entries go in the transcript in the order they start. An event without one adds to the entry
/// of its kind that's being written, or starts one.
public final class LanguageModelExecutorGenerationChannel: Sendable {
    public typealias Usage = LanguageModelSession.Usage

    public struct Event: Sendable {
        enum Kind: Sendable {
            case response(Response.Action.Kind)
            case reasoning(Reasoning.Action.Kind)
            case toolCalls(ToolCalls.Action.Kind)
        }

        let entryID: String?
        let kind: Kind

        public static func response(entryID: String? = nil, action: Response.Action) -> Event {
            Event(entryID: entryID, kind: .response(action.kind))
        }

        public static func reasoning(entryID: String? = nil, action: Reasoning.Action) -> Event {
            Event(entryID: entryID, kind: .reasoning(action.kind))
        }

        public static func toolCalls(entryID: String? = nil, action: ToolCalls.Action) -> Event {
            Event(entryID: entryID, kind: .toolCalls(action.kind))
        }
    }

    public struct Response: Sendable {
        public struct Action: Sendable {
            enum Kind: Sendable {
                case appendText(String, segmentID: String?, tokenCount: Int)
                case updateMetadata([String: GeneratedContent])
                case updateUsage(input: Usage.Input, output: Usage.Output)
            }

            let kind: Kind

            /// Adds `text` to the response's segment `segmentID`, or to its last text segment if `nil`.
            public static func appendText(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Action {
                Action(kind: .appendText(text, segmentID: segmentID, tokenCount: tokenCount))
            }

            /// Adds `values` to the entry's metadata, replacing any with the same keys.
            public static func updateMetadata(_ values: [String: any ConvertibleToGeneratedContent]) -> Action {
                Action(kind: .updateMetadata(values.mapValues(\.generatedContent)))
            }

            /// How many tokens the request took so far, which replaces what it reported before.
            public static func updateUsage(
                input: Usage.Input,
                output: Usage.Output,
                metadata: [String: any ConvertibleToGeneratedContent] = [:]
            ) -> Action {
                Action(kind: .updateUsage(input: input, output: output))
            }
        }

        public var entryID: String?
        public var action: Action
    }

    public struct Reasoning: Sendable {
        public struct Action: Sendable {
            enum Kind: Sendable {
                case appendText(String, segmentID: String?, tokenCount: Int)
                case updateSignature(Data)
                case updateMetadata([String: GeneratedContent])
                case updateUsage(input: Usage.Input, output: Usage.Output)
            }

            let kind: Kind

            public static func appendText(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Action {
                Action(kind: .appendText(text, segmentID: segmentID, tokenCount: tokenCount))
            }

            public static func updateSignature(_ signature: Data, tokenCount: Int) -> Action {
                Action(kind: .updateSignature(signature))
            }

            public static func updateMetadata(_ values: [String: any ConvertibleToGeneratedContent]) -> Action {
                Action(kind: .updateMetadata(values.mapValues(\.generatedContent)))
            }

            public static func updateUsage(
                input: Usage.Input,
                output: Usage.Output,
                metadata: [String: any ConvertibleToGeneratedContent] = [:]
            ) -> Action {
                Action(kind: .updateUsage(input: input, output: output))
            }
        }

        public var entryID: String?
        public var action: Action
    }

    public struct ToolCalls: Sendable {
        public struct Action: Sendable {
            enum Kind: Sendable {
                case toolCall(id: String, name: String, action: ToolCall.Action.Kind)
                case updateUsage(input: Usage.Input, output: Usage.Output)
            }

            let kind: Kind

            /// Adds to the call `id`, which starts it if it's new.
            public static func toolCall(id: String, name: String, action: ToolCall.Action) -> Action {
                Action(kind: .toolCall(id: id, name: name, action: action.kind))
            }

            public static func updateUsage(
                input: Usage.Input,
                output: Usage.Output,
                metadata: [String: any ConvertibleToGeneratedContent] = [:]
            ) -> Action {
                Action(kind: .updateUsage(input: input, output: output))
            }
        }

        public struct ToolCall: Sendable {
            public struct Action: Sendable {
                enum Kind: Sendable {
                    case appendArguments(String, tokenCount: Int)
                    case updateMetadata([String: GeneratedContent])
                }

                let kind: Kind

                /// Adds to the call's arguments, which are JSON once they're all sent.
                public static func appendArguments(_ content: String, tokenCount: Int) -> Action {
                    Action(kind: .appendArguments(content, tokenCount: tokenCount))
                }

                /// Adds `values` to the call's metadata, replacing any with the same keys.
                public static func updateMetadata(_ values: [String: any ConvertibleToGeneratedContent]) -> Action {
                    Action(kind: .updateMetadata(values.mapValues(\.generatedContent)))
                }
            }

            public var id: String
            public var name: String
            public var action: Action
        }

        public var entryID: String?
        public var action: Action
    }

    private let receive: @Sendable (Event) async -> Void

    init(receive: @escaping @Sendable (Event) async -> Void) {
        self.receive = receive
    }

    public func send(_ event: Event) async {
        await receive(event)
    }
}
