import Foundation
// Apple's re-exports Observation, which `Observations` of a session needs.
@_exported import Observation
import Synchronization

/// A conversation with a model, which keeps its ``transcript`` between requests.
///
/// Each prompt can take several requests to the model: when a request ends with tool calls, the
/// session runs the tools, adds their output to the transcript, and asks again, until the model
/// responds without calling one.
public final class LanguageModelSession: Observable, Sendable {
    /// How many tokens a request took, as the model reported.
    public struct Usage: Sendable, Equatable {
        public struct Input: Sendable, Equatable {
            public var totalTokenCount: Int
            /// The part of ``totalTokenCount`` the model had cached.
            public var cachedTokenCount: Int

            public init(totalTokenCount: Int, cachedTokenCount: Int = 0) {
                self.totalTokenCount = totalTokenCount
                self.cachedTokenCount = cachedTokenCount
            }
        }

        public struct Output: Sendable, Equatable {
            public var totalTokenCount: Int
            /// The part of ``totalTokenCount`` that was reasoning.
            public var reasoningTokenCount: Int

            public init(totalTokenCount: Int, reasoningTokenCount: Int = 0) {
                self.totalTokenCount = totalTokenCount
                self.reasoningTokenCount = reasoningTokenCount
            }
        }

        public var input: Input
        public var output: Output

        public init(input: Input, output: Output) {
            self.input = input
            self.output = output
        }

        static let zero = Usage(input: Input(totalTokenCount: 0), output: Output(totalTokenCount: 0))

        static func + (lhs: Usage, rhs: Usage) -> Usage {
            Usage(
                input: Input(
                    totalTokenCount: lhs.input.totalTokenCount + rhs.input.totalTokenCount,
                    cachedTokenCount: lhs.input.cachedTokenCount + rhs.input.cachedTokenCount
                ),
                output: Output(
                    totalTokenCount: lhs.output.totalTokenCount + rhs.output.totalTokenCount,
                    reasoningTokenCount: lhs.output.reasoningTokenCount + rhs.output.reasoningTokenCount
                )
            )
        }
    }

    public struct Response<Content: Sendable>: Sendable {
        public let content: Content
        public let rawContent: GeneratedContent
        /// What the response added to the transcript after its prompt.
        public let transcriptEntries: ArraySlice<Transcript.Entry>
        /// The last request's usage.
        public let usage: Usage
    }

    // MARK: State

    private enum OpenKind {
        case response
        case reasoning
    }

    private struct PendingCall {
        let id: String
        let name: String
        var arguments: String
        var metadata: [String: GeneratedContent] = [:]

        /// The call, once its arguments are complete.
        func toolCall() throws -> Transcript.ToolCall {
            do {
                let arguments = try GeneratedContent(json: arguments.isEmpty ? "{}" : arguments)
                return Transcript.ToolCall(id: id, metadata: metadata, toolName: name, arguments: arguments)
            } catch {
                throw GenerationErrors.decoding("The arguments of \(name) aren't JSON: \(arguments)")
            }
        }

        /// The call as it stands, with no arguments until they're JSON.
        var partialToolCall: Transcript.ToolCall {
            (try? toolCall()) ?? Transcript.ToolCall(id: id, metadata: metadata, toolName: name, arguments: GeneratedContent(properties: [:]))
        }
    }

    private struct State {
        var transcript: Transcript
        var isResponding = false
        var usage = Usage.zero
        /// The usage of the request in progress, or of the last one.
        var requestUsage = Usage.zero
        /// The entry text is being added to, as long as the same kind of text keeps arriving.
        var openEntry: (index: Int, kind: OpenKind)?
        /// The index of each entry the request in progress named.
        var namedEntries: [String: Int] = [:]
        var pendingCalls: [PendingCall] = []
        /// Where the request's tool calls are, when they named an entry. They're shown as they
        /// arrive, and otherwise only added once the request ends.
        var toolCallsIndex: Int?
    }

    private let registrar = ObservationRegistrar()
    private let state: Mutex<State>
    private let tools: [any Tool]
    private let toolDefinitions: [Transcript.ToolDefinition]
    private let execute: @Sendable (LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel) async throws -> Void

    /// - Parameter transcript: Where the session starts, which can be one an earlier session made.
    public init(model: some LanguageModel = SystemLanguageModel.default, tools: [any Tool] = [], transcript: Transcript) {
        // An executor that can't be made fails each request, as Apple's session does.
        let executor = Result { try type(of: model).Executor(configuration: model.executorConfiguration) }
        self.execute = { request, channel in
            try await executor.get().respond(to: request, model: model, streamingInto: channel)
        }
        self.tools = model.capabilities.contains(.toolCalling) ? tools : []
        self.toolDefinitions = self.tools.map { Transcript.ToolDefinition(tool: $0) }
        self.state = Mutex(State(transcript: transcript))
    }

    public convenience init(model: some LanguageModel = SystemLanguageModel.default, tools: [any Tool] = [], instructions: String? = nil) {
        self.init(model: model, tools: tools, instructions: instructions.map { Instructions($0) })
    }

    public convenience init(model: some LanguageModel = SystemLanguageModel.default, tools: [any Tool] = [], instructions: Instructions?) {
        var entries: [Transcript.Entry] = []
        if instructions != nil || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: instructions.map { [.text(Transcript.TextSegment(content: $0.text))] } ?? [],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )))
        }
        self.init(model: model, tools: tools, transcript: Transcript(entries: entries))
    }

    public convenience init(
        model: some LanguageModel = SystemLanguageModel.default,
        tools: [any Tool] = [],
        @InstructionsBuilder instructions: () throws -> Instructions
    ) rethrows {
        self.init(model: model, tools: tools, instructions: try instructions())
    }

    public var transcript: Transcript {
        registrar.access(self, keyPath: \.transcript)
        return state.withLock { $0.transcript }
    }

    public var isResponding: Bool {
        registrar.access(self, keyPath: \.isResponding)
        return state.withLock { $0.isResponding }
    }

    /// Every request's usage, added up.
    public var usage: Usage {
        registrar.access(self, keyPath: \.usage)
        return state.withLock { $0.usage }
    }

    /// Does nothing: models here have nothing to load.
    public func prewarm(promptPrefix: Prompt? = nil) {}

    private func changeTranscript<Result>(_ change: (inout State) throws -> Result) rethrows -> Result {
        try registrar.withMutation(of: self, keyPath: \.transcript) {
            try state.withLock { try change(&$0) }
        }
    }

    // MARK: Responding

    public func respond(to prompt: String, options: GenerationOptions = GenerationOptions()) async throws -> Response<String> {
        try await respond(to: Prompt(prompt), options: options)
    }

    public func respond(to prompt: Prompt, options: GenerationOptions = GenerationOptions()) async throws -> Response<String> {
        try await generate(prompt, as: String.self, schema: nil, options: options) { _ in }
    }

    public func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<Content> {
        try await respond(to: Prompt(prompt), generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    public func respond<Content: Generable>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<Content> {
        try await generate(prompt, as: type, schema: type.generationSchema, options: options) { _ in }
    }

    public func streamResponse(to prompt: String, options: GenerationOptions = GenerationOptions()) -> ResponseStream<String> {
        streamResponse(to: Prompt(prompt), options: options)
    }

    public func streamResponse(to prompt: Prompt, options: GenerationOptions = GenerationOptions()) -> ResponseStream<String> {
        ResponseStream { onSnapshot in
            try await self.generate(prompt, as: String.self, schema: nil, options: options, onSnapshot: onSnapshot)
        }
    }

    public func streamResponse<Content: Generable>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<Content> {
        ResponseStream { onSnapshot in
            try await self.generate(Prompt(prompt), as: type, schema: type.generationSchema, options: options, onSnapshot: onSnapshot)
        }
    }

    /// The text of the last entry if it's a response, as content of `type`.
    private static func content<Content: Generable>(of entries: ArraySlice<Transcript.Entry>, as type: Content.Type) throws -> (Content, GeneratedContent) {
        let text = responseText(of: entries)
        if let text = text as? Content {
            return (text, GeneratedContent(text))
        }
        let raw = try GeneratedContent(json: text)
        return (try Content(raw), raw)
    }

    /// What there is of the response so far, or `nil` if it can't be read yet.
    private static func partialContent<Content: Generable>(
        of entries: ArraySlice<Transcript.Entry>,
        as type: Content.Type
    ) -> (Content.PartiallyGenerated, GeneratedContent)? {
        let text = responseText(of: entries)
        if let partial = text as? Content.PartiallyGenerated {
            return (partial, GeneratedContent(text))
        }
        guard let raw = try? GeneratedContent(json: text),
              let content = try? Content.PartiallyGenerated(raw)
        else { return nil }
        return (content, raw)
    }

    private static func responseText(of entries: ArraySlice<Transcript.Entry>) -> String {
        guard case .response(let response) = entries.last else { return "" }
        return response.segments.compactMap { segment in
            if case .text(let text) = segment { text.content } else { nil }
        }
        .joined()
    }

    private func generate<Content: Generable>(
        _ prompt: Prompt,
        as type: Content.Type,
        schema: GenerationSchema?,
        options: GenerationOptions,
        onSnapshot: @escaping @Sendable (ResponseStream<Content>.Snapshot) async -> Void
    ) async throws -> Response<Content> {
        let promptIndex = try begin(Transcript.Prompt(
            segments: [.text(Transcript.TextSegment(content: prompt.text))],
            options: options,
            responseFormat: schema.map { Transcript.ResponseFormat(schema: $0) }
        ))
        defer {
            registrar.withMutation(of: self, keyPath: \.isResponding) {
                state.withLock { $0.isResponding = false }
            }
        }

        // Waits for each snapshot to be taken, so that a caller sees every step, such as a tool
        // call before the tool runs.
        let report: @Sendable () async -> Void = { [self] in
            let (entries, usage) = progress(after: promptIndex)
            if let (content, raw) = Self.partialContent(of: entries, as: type) {
                await onSnapshot(ResponseStream<Content>.Snapshot(content: content, rawContent: raw, transcriptEntries: entries, usage: usage))
            }
        }

        while true {
            try Task.checkCancellation()
            changeTranscript { state in
                state.requestUsage = .zero
                state.openEntry = nil
                state.namedEntries = [:]
                state.pendingCalls = []
                state.toolCallsIndex = nil
            }
            let request = LanguageModelExecutorGenerationRequest(
                id: UUID(),
                transcript: transcript,
                enabledTools: toolDefinitions,
                schema: schema,
                generationOptions: options,
                contextOptions: ContextOptions(),
                metadata: [:]
            )
            let channel = LanguageModelExecutorGenerationChannel { [self] event in
                receive(event)
                await report()
            }
            try await execute(request, channel)

            let (pending, toolCallsIndex) = changeTranscript { state in
                defer { state.pendingCalls = [] }
                return (state.pendingCalls, state.toolCallsIndex)
            }
            guard !pending.isEmpty else { break }
            let calls = try pending.map { try $0.toolCall() }
            changeTranscript { state in
                if let toolCallsIndex {
                    state.transcript.update(at: toolCallsIndex) { entry in
                        if case .toolCalls(let shown) = entry {
                            entry = .toolCalls(Transcript.ToolCalls(id: shown.id, calls))
                        }
                    }
                } else {
                    state.transcript.append(.toolCalls(Transcript.ToolCalls(calls)))
                }
                state.openEntry = nil
            }
            await report()

            for call in calls {
                try Task.checkCancellation()
                guard let tool = tools.first(where: { $0.name == call.toolName }) else {
                    throw GenerationErrors.decoding("The model called \(call.toolName), which isn't one of the session's tools")
                }
                let segments: [Transcript.Segment]
                do {
                    segments = try await tool.run(with: call.arguments)
                } catch let error as ToolArgumentsError {
                    throw GenerationErrors.decoding("The arguments of \(call.toolName) don't fit its schema: \(error.underlyingError)")
                } catch {
                    throw ToolCallError(tool: tool, underlyingError: error)
                }
                changeTranscript { state in
                    state.transcript.append(.toolOutput(Transcript.ToolOutput(id: call.id, toolName: call.toolName, segments: segments)))
                }
                await report()
            }
        }

        let (entries, usage) = progress(after: promptIndex)
        let (content, raw) = try Self.content(of: entries, as: type)
        return Response(content: content, rawContent: raw, transcriptEntries: entries, usage: usage)
    }

    /// Adds `prompt` to the transcript, and returns its index.
    private func begin(_ prompt: Transcript.Prompt) throws -> Int {
        try registrar.withMutation(of: self, keyPath: \.isResponding) {
            try changeTranscript { state in
                guard !state.isResponding else {
                    throw GenerationError.concurrentRequests(.init(debugDescription: "The session is already responding."))
                }
                state.isResponding = true
                state.transcript.append(.prompt(prompt))
                return state.transcript.count - 1
            }
        }
    }

    /// The entries after the prompt at `promptIndex`, and the latest request's usage.
    private func progress(after promptIndex: Int) -> (ArraySlice<Transcript.Entry>, Usage) {
        state.withLock { state in
            (ArraySlice(state.transcript[(promptIndex + 1)...]), state.requestUsage)
        }
    }

    private func receive(_ event: LanguageModelExecutorGenerationChannel.Event) {
        let entryID = event.entryID
        switch event.kind {
        case .response(.appendText(let text, let segmentID, _)):
            changeTranscript { Self.append(text, segmentID: segmentID, to: .response, entryID: entryID, in: &$0) }
        case .reasoning(.appendText(let text, let segmentID, _)):
            changeTranscript { Self.append(text, segmentID: segmentID, to: .reasoning, entryID: entryID, in: &$0) }
        case .reasoning(.updateSignature(let signature)):
            changeTranscript { state in
                let index = Self.entry(.reasoning, id: entryID, in: &state)
                state.transcript.update(at: index) { entry in
                    if case .reasoning(var reasoning) = entry {
                        reasoning.signature = signature
                        entry = .reasoning(reasoning)
                    }
                }
            }
        case .response(.updateMetadata(let values)):
            changeTranscript { state in
                let index = Self.entry(.response, id: entryID, in: &state)
                state.transcript.update(at: index) { entry in
                    if case .response(var response) = entry {
                        response.metadata.merge(values) { _, new in new }
                        entry = .response(response)
                    }
                }
            }
        case .reasoning(.updateMetadata(let values)):
            changeTranscript { state in
                let index = Self.entry(.reasoning, id: entryID, in: &state)
                state.transcript.update(at: index) { entry in
                    if case .reasoning(var reasoning) = entry {
                        reasoning.metadata.merge(values) { _, new in new }
                        entry = .reasoning(reasoning)
                    }
                }
            }
        case .toolCalls(.toolCall(let id, let name, let action)):
            changeTranscript { state in
                let index = state.pendingCalls.firstIndex { $0.id == id } ?? {
                    state.pendingCalls.append(PendingCall(id: id, name: name, arguments: ""))
                    return state.pendingCalls.count - 1
                }()
                switch action {
                case .appendArguments(let arguments, _):
                    state.pendingCalls[index].arguments += arguments
                case .updateMetadata(let values):
                    state.pendingCalls[index].metadata.merge(values) { _, new in new }
                }
                if let entryID {
                    Self.showToolCalls(entryID: entryID, in: &state)
                }
            }
        case .response(.updateUsage(let input, let output)),
             .reasoning(.updateUsage(let input, let output)),
             .toolCalls(.updateUsage(let input, let output)):
            registrar.withMutation(of: self, keyPath: \.usage) {
                state.withLock { state in
                    let usage = Usage(input: input, output: output)
                    // A request can report again as it goes, so only the change is added.
                    state.usage = state.usage + Usage(
                        input: .init(
                            totalTokenCount: usage.input.totalTokenCount - state.requestUsage.input.totalTokenCount,
                            cachedTokenCount: usage.input.cachedTokenCount - state.requestUsage.input.cachedTokenCount
                        ),
                        output: .init(
                            totalTokenCount: usage.output.totalTokenCount - state.requestUsage.output.totalTokenCount,
                            reasoningTokenCount: usage.output.reasoningTokenCount - state.requestUsage.output.reasoningTokenCount
                        )
                    )
                    state.requestUsage = usage
                }
            }
        }
    }

    /// Puts the request's tool calls so far in the entry `entryID`, which starts it if it's new.
    private static func showToolCalls(entryID: String, in state: inout State) {
        let calls = Transcript.ToolCalls(id: entryID, state.pendingCalls.map(\.partialToolCall))
        if let index = state.toolCallsIndex {
            state.transcript.update(at: index) { $0 = .toolCalls(calls) }
        } else {
            state.transcript.append(.toolCalls(calls))
            state.toolCallsIndex = state.transcript.count - 1
            state.openEntry = nil
        }
    }

    /// The index of the entry `id`, or without one, of the entry of `kind` that text is being
    /// added to. Either is started if there isn't one.
    private static func entry(_ kind: OpenKind, id: String?, in state: inout State) -> Int {
        guard let id else { return openEntry(kind, in: &state) }
        if let index = state.namedEntries[id] {
            return index
        }
        switch kind {
        case .response:
            state.transcript.append(.response(Transcript.Response(id: id, assetIDs: [], segments: [])))
        case .reasoning:
            state.transcript.append(.reasoning(Transcript.Reasoning(id: id, segments: [], signature: nil)))
        }
        let index = state.transcript.count - 1
        state.namedEntries[id] = index
        state.openEntry = (index, kind)
        return index
    }

    /// The index of the entry of `kind` that text is being added to, which is started if there isn't one.
    private static func openEntry(_ kind: OpenKind, in state: inout State) -> Int {
        if let open = state.openEntry, open.kind == kind, open.index == state.transcript.count - 1 {
            return open.index
        }
        switch kind {
        case .response:
            state.transcript.append(.response(Transcript.Response(assetIDs: [], segments: [])))
        case .reasoning:
            state.transcript.append(.reasoning(Transcript.Reasoning(segments: [], signature: nil)))
        }
        let index = state.transcript.count - 1
        state.openEntry = (index, kind)
        return index
    }

    private static func append(_ text: String, segmentID: String?, to kind: OpenKind, entryID: String?, in state: inout State) {
        let index = entry(kind, id: entryID, in: &state)
        state.transcript.update(at: index) { entry in
            switch entry {
            case .response(var response):
                response.segments = appending(text, segmentID: segmentID, to: response.segments)
                entry = .response(response)
            case .reasoning(var reasoning):
                reasoning.segments = appending(text, segmentID: segmentID, to: reasoning.segments)
                entry = .reasoning(reasoning)
            default:
                break
            }
        }
    }

    /// Adds `text` to the segment `segmentID`, or to the last text segment if that's `nil`.
    private static func appending(_ text: String, segmentID: String?, to segments: [Transcript.Segment]) -> [Transcript.Segment] {
        var segments = segments
        let index = segments.lastIndex { segment in
            guard case .text(let textSegment) = segment else { return false }
            return segmentID == nil || textSegment.id == segmentID
        }
        if let index, case .text(var segment) = segments[index] {
            segment.content += text
            segments[index] = .text(segment)
        } else if let segmentID {
            segments.append(.text(Transcript.TextSegment(id: segmentID, content: text)))
        } else {
            segments.append(.text(Transcript.TextSegment(content: text)))
        }
        return segments
    }
}

extension LanguageModelSession {
    /// A response as it's generated. Iterating it starts the response, and so does ``collect()``.
    public struct ResponseStream<Content: Generable>: AsyncSequence, Sendable {
        public struct Snapshot: Sendable {
            public let content: Content.PartiallyGenerated
            public let rawContent: GeneratedContent
            /// What the response has added to the transcript after its prompt so far.
            public let transcriptEntries: ArraySlice<Transcript.Entry>
            /// The latest request's usage, which the model reports at the end of each request.
            public let usage: Usage
        }

        public typealias Element = Snapshot

        private let run: @Sendable (@escaping @Sendable (Snapshot) async -> Void) async throws -> Response<Content>

        init(run: @escaping @Sendable (@escaping @Sendable (Snapshot) async -> Void) async throws -> Response<Content>) {
            self.run = run
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var base: AsyncThrowingStream<Snapshot, any Error>.AsyncIterator
            let taken: Permits
            var hasTakenOne = false

            public mutating func next() async throws -> Snapshot? {
                // Asking for the next snapshot means the last one has been dealt with.
                if hasTakenOne {
                    taken.release()
                }
                hasTakenOne = true
                return try await base.next()
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            let (stream, continuation) = AsyncThrowingStream<Snapshot, any Error>.makeStream()
            let taken = Permits()
            let run = run
            let task = Task {
                do {
                    _ = try await run { snapshot in
                        continuation.yield(snapshot)
                        await taken.acquire()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                taken.close()
                task.cancel()
            }
            return AsyncIterator(base: stream.makeAsyncIterator(), taken: taken)
        }

        /// Waits for the whole response.
        public func collect() async throws -> Response<Content> {
            try await run { _ in }
        }
    }
}

/// Counts snapshots taken, for the session to wait on. Once closed, nothing waits.
final class Permits: Sendable {
    private struct State {
        var available = 0
        var waiting: CheckedContinuation<Void, Never>?
        var isClosed = false
    }

    private let state = Mutex(State())

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.isClosed { return true }
                if state.available > 0 {
                    state.available -= 1
                    return true
                }
                state.waiting = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if let waiting = state.waiting {
                state.waiting = nil
                return waiting
            }
            state.available += 1
            return nil
        }
        waiting?.resume()
    }

    func close() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isClosed = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }
}
