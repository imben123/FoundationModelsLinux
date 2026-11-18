import Foundation

/// Something a model can call while it responds.
public protocol Tool<Arguments, Output>: Sendable {
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Output: PromptRepresentable

    /// Unique among a session's tools.
    var name: String { get }
    /// When the model should call the tool, in plain language.
    var description: String { get }
    /// The schema of ``Arguments``.
    var parameters: GenerationSchema { get }
    /// Whether the model is told the schema in its instructions.
    var includesSchemaInInstructions: Bool { get }

    func call(arguments: Arguments) async throws -> Output
}

extension Tool {
    public var name: String { String(describing: Self.self) }
    public var includesSchemaInInstructions: Bool { true }
}

extension Tool where Arguments: Generable {
    public var parameters: GenerationSchema { Arguments.generationSchema }
}

/// Why a tool call couldn't start, as opposed to the tool failing.
struct ToolArgumentsError: Error {
    let underlyingError: any Error
}

extension Tool {
    /// Calls the tool with `arguments`, and gives back its output as a transcript's segments.
    ///
    /// - Throws: ``ToolArgumentsError`` if `arguments` aren't the tool's, otherwise what the tool throws.
    func run(with arguments: GeneratedContent) async throws -> [Transcript.Segment] {
        let decoded: Arguments
        do {
            decoded = try Arguments(arguments)
        } catch {
            throw ToolArgumentsError(underlyingError: error)
        }
        let output = try await call(arguments: decoded)
        if let text = output as? String {
            return [.text(Transcript.TextSegment(content: text))]
        }
        if let content = output as? any ConvertibleToGeneratedContent {
            return [.structure(Transcript.StructuredSegment(source: name, content: content.generatedContent))]
        }
        return output.promptRepresentation.segments
    }
}
