import Foundation

/// Apple's on-device model, which isn't on this platform.
public final class SystemLanguageModel: LanguageModel {
    public enum Availability: Sendable, Equatable {
        public enum UnavailableReason: Sendable, Equatable {
            case deviceNotEligible
            case appleIntelligenceNotEnabled
            case modelNotReady
        }

        case available
        case unavailable(UnavailableReason)
    }

    public struct Executor: LanguageModelExecutor {
        public typealias Model = SystemLanguageModel

        public init(configuration: Int) {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: SystemLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            throw LanguageModelSession.GenerationError.assetsUnavailable(
                .init(debugDescription: "Apple's on-device model is only on Apple platforms.")
            )
        }
    }

    public static let `default` = SystemLanguageModel()

    public init() {}

    public var availability: Availability { .unavailable(.deviceNotEligible) }
    public var isAvailable: Bool { availability == .available }
    /// The on-device model's context, in tokens.
    public var contextSize: Int { 4096 }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .guidedGeneration]) }
    public var executorConfiguration: Int { 0 }

    /// - Throws: Always, because the model isn't here to count with.
    public func tokenCount(for transcript: Transcript) async throws -> Int {
        throw LanguageModelSession.GenerationError.assetsUnavailable(
            .init(debugDescription: "Apple's on-device model is only on Apple platforms.")
        )
    }
}

/// Apple's Private Cloud Compute model, which isn't on this platform.
public struct PrivateCloudComputeLanguageModel: LanguageModel {
    public enum Availability: Sendable, Equatable {
        public enum UnavailableReason: Sendable, Equatable {
            case deviceNotEligible
            case appleIntelligenceNotEnabled
            case modelNotReady
        }

        case available
        case unavailable(UnavailableReason)
    }

    public enum Error: Swift.Error, LocalizedError {
        public struct Context: Sendable {
            public let debugDescription: String

            public init(debugDescription: String) {
                self.debugDescription = debugDescription
            }
        }

        public struct QuotaLimit: Sendable {
            public let limitIncreaseSuggestion: String?
            /// When the quota resets, if the service says.
            public let resetDate: Date?
            public let debugDescription: String

            public init(limitIncreaseSuggestion: String?, resetDate: Date?, debugDescription: String) {
                self.limitIncreaseSuggestion = limitIncreaseSuggestion
                self.resetDate = resetDate
                self.debugDescription = debugDescription
            }
        }

        case networkFailure(Context)
        case serviceUnavailable(Context)
        case quotaLimitReached(QuotaLimit)

        public var errorDescription: String? {
            switch self {
            case .networkFailure: "Couldn't reach Private Cloud Compute."
            case .serviceUnavailable: "Private Cloud Compute is unavailable."
            case .quotaLimitReached: "The Private Cloud Compute quota has been reached."
            }
        }
    }

    public struct Executor: LanguageModelExecutor {
        public typealias Model = PrivateCloudComputeLanguageModel

        public init(configuration: Int) {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: PrivateCloudComputeLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            throw PrivateCloudComputeLanguageModel.Error.serviceUnavailable(
                .init(debugDescription: "Private Cloud Compute is only on Apple platforms.")
            )
        }
    }

    public init() {}

    public var availability: Availability { .unavailable(.deviceNotEligible) }

    /// - Throws: Always, because the service isn't here to ask.
    public var contextSize: Int {
        get async throws {
            throw Error.serviceUnavailable(.init(debugDescription: "Private Cloud Compute is only on Apple platforms."))
        }
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .guidedGeneration]) }
    public var executorConfiguration: Int { 0 }
}
