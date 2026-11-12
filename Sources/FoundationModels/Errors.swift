import Foundation

extension LanguageModelSession {
    /// Why a session couldn't generate a response.
    public enum GenerationError: Error, LocalizedError {
        public struct Context: Sendable {
            public let debugDescription: String

            public init(debugDescription: String) {
                self.debugDescription = debugDescription
            }
        }

        case exceededContextWindowSize(Context)
        case assetsUnavailable(Context)
        case guardrailViolation(Context)
        case unsupportedGuide(Context)
        case unsupportedLanguageOrLocale(Context)
        case decodingFailure(Context)
        case rateLimited(Context)
        case concurrentRequests(Context)

        public var context: Context {
            switch self {
            case .exceededContextWindowSize(let context), .assetsUnavailable(let context),
                 .guardrailViolation(let context), .unsupportedGuide(let context),
                 .unsupportedLanguageOrLocale(let context), .decodingFailure(let context),
                 .rateLimited(let context), .concurrentRequests(let context):
                context
            }
        }

        public var errorDescription: String? {
            switch self {
            case .exceededContextWindowSize: "The conversation is too long for the model."
            case .assetsUnavailable: "The model is unavailable."
            case .guardrailViolation: "The model's guardrails stopped the response."
            case .unsupportedGuide: "The model doesn't support a guide in the schema."
            case .unsupportedLanguageOrLocale: "The model doesn't support this language."
            case .decodingFailure: "The model's response couldn't be read."
            case .rateLimited: "The model has had too many requests."
            case .concurrentRequests: "The session is already responding."
            }
        }

        public var failureReason: String? { context.debugDescription }
    }

    /// A tool that threw while the model was responding.
    public struct ToolCallError: Error, LocalizedError {
        public var tool: any Tool
        public var underlyingError: any Error

        public init(tool: any Tool, underlyingError: any Error) {
            self.tool = tool
            self.underlyingError = underlyingError
        }

        public var errorDescription: String? {
            "The tool \(tool.name) failed: \(underlyingError.localizedDescription)"
        }
    }
}

/// An error from any language model.
public enum LanguageModelError: Error, LocalizedError {
    public struct ContextSizeExceeded: Sendable {
        public var contextSize: Int
        public var tokenCount: Int
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(contextSize: Int, tokenCount: Int, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.contextSize = contextSize
            self.tokenCount = tokenCount
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct RateLimited: Sendable {
        public var resetDate: Date?
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(resetDate: Date?, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.resetDate = resetDate
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct GuardrailViolation: Sendable {
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct Refusal: Sendable {
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        let explanation: String

        public init(explanation: String, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.explanation = explanation
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedCapability: Sendable {
        public var capability: LanguageModelCapabilities.Capability
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(capability: LanguageModelCapabilities.Capability, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.capability = capability
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedTranscriptContent: Sendable {
        public var unsupportedContent: [Transcript.Entry]
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(unsupportedContent: [Transcript.Entry], debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.unsupportedContent = unsupportedContent
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedGenerationGuide: Sendable {
        public var schemaName: String?
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(schemaName: String?, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.schemaName = schemaName
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedLanguageOrLocale: Sendable {
        public var languageCode: Locale.LanguageCode
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(languageCode: Locale.LanguageCode, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.languageCode = languageCode
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct Timeout: Sendable {
        public var debugDescription: String
        public var metadata: [String: any Sendable]

        public init(debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    case contextSizeExceeded(ContextSizeExceeded)
    case rateLimited(RateLimited)
    case guardrailViolation(GuardrailViolation)
    case refusal(Refusal)
    case unsupportedCapability(UnsupportedCapability)
    case unsupportedTranscriptContent(UnsupportedTranscriptContent)
    case unsupportedGenerationGuide(UnsupportedGenerationGuide)
    case unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)
    case timeout(Timeout)

    public var errorDescription: String? {
        switch self {
        case .contextSizeExceeded(let context):
            "The conversation is \(context.tokenCount) tokens, more than the model's \(context.contextSize)."
        case .rateLimited: "The model has had too many requests."
        case .guardrailViolation: "The model's guardrails stopped the response."
        case .refusal(let refusal): refusal.explanation
        case .unsupportedCapability: "The model can't do what the request needs."
        case .unsupportedTranscriptContent: "The model can't read part of the conversation."
        case .unsupportedGenerationGuide: "The model doesn't support a guide in the schema."
        case .unsupportedLanguageOrLocale: "The model doesn't support this language."
        case .timeout: "The model took too long to respond."
        }
    }

    public var failureReason: String? {
        switch self {
        case .contextSizeExceeded(let context): context.debugDescription
        case .rateLimited(let context): context.debugDescription
        case .guardrailViolation(let context): context.debugDescription
        case .refusal(let context): context.debugDescription
        case .unsupportedCapability(let context): context.debugDescription
        case .unsupportedTranscriptContent(let context): context.debugDescription
        case .unsupportedGenerationGuide(let context): context.debugDescription
        case .unsupportedLanguageOrLocale(let context): context.debugDescription
        case .timeout(let context): context.debugDescription
        }
    }
}
