import Foundation
import FoundationModels
import Synchronization
import Testing

/// Sends each request's events in turn, and records the requests.
final class ScriptedModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    typealias Event = LanguageModelExecutorGenerationChannel.Event

    private let script: Mutex<[[Event]]>
    private let recorded = Mutex<[LanguageModelExecutorGenerationRequest]>([])
    let failure: (any Error)?
    let dataTypes: [UTType]

    init(_ script: [[Event]], failure: (any Error)? = nil, dataTypes: [UTType] = []) {
        self.script = Mutex(script)
        self.failure = failure
        self.dataTypes = dataTypes
    }

    func supportsDataAttachmentType(_ type: UTType) async throws -> Bool {
        dataTypes.contains { type.conforms(to: $0) }
    }

    var requests: [LanguageModelExecutorGenerationRequest] { recorded.withLock { $0 } }

    func next(for request: LanguageModelExecutorGenerationRequest) -> [Event] {
        recorded.withLock { $0.append(request) }
        return script.withLock { $0.isEmpty ? [] : $0.removeFirst() }
    }

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .reasoning]) }
    var executorConfiguration: Int { 0 }
}

struct ScriptedExecutor: LanguageModelExecutor {
    init(configuration: Int) {}

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        for event in model.next(for: request) {
            await channel.send(event)
        }
        if let failure = model.failure {
            throw failure
        }
    }
}

private func text(_ text: String) -> LanguageModelExecutorGenerationChannel.Event {
    .response(action: .appendText(text, segmentID: nil, tokenCount: 0))
}

private func reasoning(_ text: String) -> LanguageModelExecutorGenerationChannel.Event {
    .reasoning(action: .appendText(text, segmentID: nil, tokenCount: 0))
}

private func call(_ id: String, _ name: String, _ arguments: String) -> LanguageModelExecutorGenerationChannel.Event {
    .toolCalls(action: .toolCall(id: id, name: name, action: .appendArguments(arguments, tokenCount: 0)))
}

private func usage(_ input: Int, _ output: Int) -> LanguageModelExecutorGenerationChannel.Event {
    .response(action: .updateUsage(input: .init(totalTokenCount: input, cachedTokenCount: 0), output: .init(totalTokenCount: output, reasoningTokenCount: 0)))
}

struct EchoTool: Tool {
    let name = "echo"
    let description = "Says the text back."

    @Generable
    struct Arguments {
        @Guide(description: "What to say")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        "Echo: \(arguments.text)"
    }
}

struct FailingTool: Tool {
    struct Failure: Error {}

    let name = "fail"
    let description = "Always fails."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        throw Failure()
    }
}

private func kinds(_ entries: some Sequence<Transcript.Entry>) -> [String] {
    entries.map { entry in
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .reasoning: "reasoning"
        case .response: "response"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        }
    }
}

@Test func aResponseIsStreamedIntoTheTranscript() async throws {
    let model = ScriptedModel([[text("Hel"), text("lo"), usage(10, 2)]])
    let session = LanguageModelSession(model: model, instructions: "Be brief")

    let response = try await session.respond(to: "Hi")

    #expect(response.content == "Hello")
    #expect(response.usage.input.totalTokenCount == 10)
    #expect(kinds(session.transcript) == ["instructions", "prompt", "response"])
    #expect(kinds(response.transcriptEntries) == ["response"])
    #expect(!session.isResponding)
    #expect(kinds(model.requests[0].transcript) == ["instructions", "prompt"])
}

@Test func toolsRunBetweenRequestsUntilTheModelAnswers() async throws {
    let model = ScriptedModel([
        [reasoning("Echo it"), call("1", "echo", #"{"text":"#), call("1", "echo", #""hi"}"#)],
        [reasoning("Done"), text("It said hi")],
    ])
    let session = LanguageModelSession(model: model, tools: [EchoTool()], instructions: "Be brief")

    let response = try await session.respond(to: "Echo hi")

    #expect(response.content == "It said hi")
    #expect(kinds(session.transcript) == ["instructions", "prompt", "reasoning", "toolCalls", "toolOutput", "reasoning", "response"])
    guard case .toolCalls(let calls) = session.transcript[3], case .toolOutput(let output) = session.transcript[4] else {
        Issue.record("Unexpected transcript: \(session.transcript)")
        return
    }
    #expect(calls.first?.arguments.jsonString == #"{"text":"hi"}"#)
    #expect(output.id == "1")
    #expect(output.segments.description.contains("Echo: hi"))
    #expect(model.requests.count == 2)
    #expect(model.requests[0].enabledToolDefinitions.map(\.name) == ["echo"])
    #expect(kinds(model.requests[1].transcript).suffix(2) == ["toolCalls", "toolOutput"])
}

@Test func aNewEntryStartsWhenTheKindOfTextChanges() async throws {
    let model = ScriptedModel([[reasoning("a"), reasoning("b"), text("c"), reasoning("d"), text("e")]])
    let session = LanguageModelSession(model: model)

    _ = try await session.respond(to: "Hi")

    #expect(kinds(session.transcript) == ["prompt", "reasoning", "response", "reasoning", "response"])
}

/// Claude's executor names the entry each event belongs to, as Apple's sessions allow.
@Test func eventsThatNameAnEntryAddToIt() async throws {
    typealias Event = LanguageModelExecutorGenerationChannel.Event
    let model = ScriptedModel([
        [
            .reasoning(entryID: "think1", action: .appendText("First", tokenCount: 1)),
            .reasoning(entryID: "think2", action: .appendText("Second", tokenCount: 1)),
            .reasoning(entryID: "think1", action: .updateSignature(Data("sig".utf8), tokenCount: 0)),
            .reasoning(entryID: "think1", action: .updateMetadata(["record": "a"])),
            .toolCalls(entryID: "calls", action: .toolCall(id: "c1", name: "echo", action: .appendArguments("", tokenCount: 0))),
            .toolCalls(entryID: "calls", action: .toolCall(id: "c1", name: "echo", action: .appendArguments(#"{"text":"hi"}"#, tokenCount: 1))),
            .toolCalls(entryID: "calls", action: .toolCall(id: "c1", name: "echo", action: .updateMetadata(["record": "b"]))),
            // Usage alone starts no entry.
            .response(entryID: "answer", action: .updateUsage(input: .init(totalTokenCount: 10, cachedTokenCount: 0), output: .init(totalTokenCount: 2, reasoningTokenCount: 0))),
        ],
        [
            .response(entryID: "answer", action: .appendText("Done", tokenCount: 1)),
            .response(entryID: "answer", action: .updateMetadata(["record": "c"])),
            .response(entryID: "answer", action: .updateMetadata(["model": "m"])),
        ],
    ])
    let session = LanguageModelSession(model: model, tools: [EchoTool()])

    let response = try await session.respond(to: "Hi")

    #expect(kinds(response.transcriptEntries) == ["reasoning", "reasoning", "toolCalls", "toolOutput", "response"])
    let entries = Array(response.transcriptEntries)
    guard case .reasoning(let first) = entries[0], case .reasoning(let second) = entries[1],
          case .toolCalls(let calls) = entries[2], case .response(let answer) = entries[4]
    else {
        Issue.record("The entries aren't the expected kinds")
        return
    }
    #expect(first.id == "think1" && first.signature == Data("sig".utf8) && first.metadata["record"] == GeneratedContent("a"))
    #expect(second.id == "think2" && second.signature == nil && second.metadata.isEmpty)
    #expect(calls.id == "calls")
    #expect(calls.first?.arguments.jsonString == #"{"text":"hi"}"#)
    #expect(calls.first?.metadata["record"] == GeneratedContent("b"))
    #expect(answer.id == "answer")
    #expect(answer.metadata == ["record": GeneratedContent("c"), "model": GeneratedContent("m")])
}

/// Tool calls that name an entry are in the transcript as they arrive, before the request ends.
@Test func namedToolCallsAreShownAsTheyArrive() async throws {
    let model = ScriptedModel([
        [
            .toolCalls(entryID: "calls", action: .toolCall(id: "c1", name: "echo", action: .appendArguments(#"{"te"#, tokenCount: 1))),
            .toolCalls(entryID: "calls", action: .toolCall(id: "c1", name: "echo", action: .appendArguments(#"xt":"hi"}"#, tokenCount: 1))),
        ],
        [text("Done")],
    ])
    let session = LanguageModelSession(model: model, tools: [EchoTool()])
    var arguments: [String] = []
    for try await snapshot in session.streamResponse(to: "Hi") {
        for case .toolCalls(let calls) in snapshot.transcriptEntries {
            arguments.append(calls.first?.arguments.jsonString ?? "")
        }
    }
    #expect(arguments.prefix(2) == ["{}", #"{"text":"hi"}"#])
}

@Test func aFailingToolIsReportedWithTheTool() async throws {
    let model = ScriptedModel([[call("1", "fail", "")]])
    let session = LanguageModelSession(model: model, tools: [FailingTool()])

    await #expect {
        try await session.respond(to: "Fail")
    } throws: { error in
        guard let error = error as? LanguageModelSession.ToolCallError else { return false }
        return error.tool.name == "fail" && error.underlyingError is FailingTool.Failure
    }
    // The call stays, without output, because it was made.
    #expect(kinds(session.transcript).last == "toolCalls")
    #expect(!session.isResponding)
}

@Test func aCallToAnUnknownToolCantBeRead() async throws {
    let model = ScriptedModel([[call("1", "missing", "{}")]])
    let session = LanguageModelSession(model: model, tools: [EchoTool()])

    await #expect(throws: LanguageModelSession.GenerationError.self) {
        try await session.respond(to: "Hi")
    }
}

@Test func theModelsErrorsPassThrough() async throws {
    struct ProviderError: Error {}
    let session = LanguageModelSession(model: ScriptedModel([[text("Hal")]], failure: ProviderError()))

    await #expect(throws: ProviderError.self) {
        try await session.respond(to: "Hi")
    }
}

@Test func aSecondRequestWhileRespondingIsRefused() async throws {
    let model = ScriptedModel([[text("One")], [text("Two")]])
    let session = LanguageModelSession(model: model)

    var iterator = session.streamResponse(to: "First").makeAsyncIterator()
    _ = try await iterator.next()

    await #expect(throws: LanguageModelSession.GenerationError.self) {
        try await session.respond(to: "Second")
    }
    while try await iterator.next() != nil {}
    #expect(try await session.respond(to: "Second").content == "Two")
}

/// So that a caller sees a tool call before the tool runs, however slowly it reads.
@Test func eachStepIsStreamedBeforeTheNextHappens() async throws {
    let model = ScriptedModel([[call("1", "echo", #"{"text":"hi"}"#)], [text("Done")]])
    let session = LanguageModelSession(model: model, tools: [EchoTool()])

    var seen: [[String]] = []
    for try await snapshot in session.streamResponse(to: "Echo hi") {
        try await Task.sleep(for: .milliseconds(5))
        seen.append(kinds(snapshot.transcriptEntries))
    }

    #expect(seen.contains(["toolCalls"]))
    #expect(seen.contains(["toolCalls", "toolOutput"]))
    #expect(seen.last == ["toolCalls", "toolOutput", "response"])
}

@Test func aSnapshotsUsageIsTheLatestRequests() async throws {
    let model = ScriptedModel([
        [call("1", "echo", #"{"text":"hi"}"#), usage(100, 5)],
        [text("Done"), usage(130, 10)],
    ])
    let session = LanguageModelSession(model: model, tools: [EchoTool()])

    var last: LanguageModelSession.Usage?
    for try await snapshot in session.streamResponse(to: "Echo hi") {
        last = snapshot.usage
    }

    #expect(last?.input.totalTokenCount == 130)
    #expect(session.usage.input.totalTokenCount == 230)
}

@Test func aGenerableResponseIsReadFromItsJSON() async throws {
    let model = ScriptedModel([[text(#"{"name":"Ada","age":36,"emails":[]}"#)]])
    let session = LanguageModelSession(model: model)

    let response = try await session.respond(to: "Who?", generating: Contact.self)

    #expect(response.content.name == "Ada")
    #expect(model.requests.first?.schema == Contact.generationSchema)
}

@Test func aTranscriptRoundTripsThroughJSON() async throws {
    let model = ScriptedModel([[reasoning("Hmm"), call("1", "echo", #"{"text":"hi"}"#)], [text("Done")]])
    let session = LanguageModelSession(model: model, tools: [EchoTool()], instructions: "Be brief")
    _ = try await session.respond(to: "Echo hi")

    let data = try JSONEncoder().encode(session.transcript)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)

    #expect(kinds(decoded) == kinds(session.transcript))
    #expect(decoded.description == session.transcript.description)
}

@Test func toolDefinitionsAreInTheInstructions() {
    let session = LanguageModelSession(tools: [EchoTool()], instructions: "Be brief")

    guard case .instructions(let instructions) = session.transcript.first else {
        Issue.record("No instructions")
        return
    }
    #expect(instructions.toolDefinitions.map(\.name) == ["echo"])
    #expect("\(session.transcript)".contains("echo"))
}

@Test func applesModelsAreUnavailableHere() async {
    #expect(!SystemLanguageModel.default.isAvailable)
    #expect(PrivateCloudComputeLanguageModel().availability == .unavailable(.deviceNotEligible))
    await #expect(throws: LanguageModelSession.GenerationError.self) {
        try await LanguageModelSession().respond(to: "Hi")
    }
}

@Test func theTranscriptCanBeObserved() async throws {
    let model = ScriptedModel([[text("Hi")]])
    let session = LanguageModelSession(model: model)
    let watch = Task {
        for await transcript in Observations({ session.transcript }) where kinds(transcript).last == "response" {
            return true
        }
        return false
    }

    _ = try await session.respond(to: "Hello")

    #expect(await watch.value)
}

@Test func aPromptsAttachmentsAreSegmentsOfTheirOwn() async throws {
    let model = ScriptedModel([[text("A dot")]])
    let session = LanguageModelSession(model: model)
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    _ = try await session.respond(to: Prompt {
        Attachment(data: jpeg, mediaType: "image/jpeg")
        "What's this?"
        "Be brief"
    })

    guard case .prompt(let prompt) = model.requests[0].transcript.last else {
        Issue.record("The request ends with no prompt")
        return
    }
    #expect(prompt.segments.count == 2)
    guard case .attachment(let attachment) = prompt.segments.first, case .image(let image) = attachment.content else {
        Issue.record("The prompt doesn't start with its image")
        return
    }
    #expect(image == Transcript.ImageAttachment(data: jpeg, mediaType: "image/jpeg"))
    guard case .text(let text) = prompt.segments.last else {
        Issue.record("The prompt doesn't end with its text")
        return
    }
    #expect(text.content == "What's this?\nBe brief")

    let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(session.transcript))
    #expect(decoded == session.transcript)
}

@Test func aPromptOfTextAloneIsOneSegment() async throws {
    let model = ScriptedModel([[text("Hi")]])
    let session = LanguageModelSession(model: model)
    _ = try await session.respond(to: "Hello")
    guard case .prompt(let prompt) = model.requests[0].transcript.last, case .text(let text) = prompt.segments.first else {
        Issue.record("The request ends with no text prompt")
        return
    }
    #expect(prompt.segments.count == 1)
    #expect(text.content == "Hello")
}

struct PDF: DataAttachmentRepresentable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(_ attachment: Transcript.DataAttachment) throws {
        data = attachment.content
    }

    var transcriptRepresentation: Transcript.DataAttachment {
        Transcript.DataAttachment(contentType: .pdf, content: data)
    }
}

@Test func aModelThatSupportsAFilesTypeIsSentIt() async throws {
    let model = ScriptedModel([[text("A letter")]], dataTypes: [.pdf])
    let session = LanguageModelSession(model: model)
    let pdf = Data("%PDF-1.4".utf8)

    _ = try await session.respond(to: Prompt {
        Attachment(PDF(data: pdf))
        "What's this?"
    })

    guard case .prompt(let prompt) = model.requests[0].transcript.last,
          case .attachment(let attachment) = prompt.segments.first,
          case .data(let data) = attachment.content
    else {
        Issue.record("The prompt doesn't start with its PDF")
        return
    }
    #expect(data == Transcript.DataAttachment(contentType: .pdf, content: pdf))
    #expect(try PDF(data).data == pdf)
    #expect(attachment.description == "Data(com.adobe.pdf, 8 bytes)")

    let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(session.transcript))
    #expect(decoded == session.transcript)
}

@Test func aFileTheModelDoesntSupportIsRefusedBeforeItsSent() async throws {
    let model = ScriptedModel([[text("A letter")]])
    let session = LanguageModelSession(model: model)

    await #expect {
        try await session.respond(to: Prompt {
            Attachment(PDF(data: Data("%PDF-1.4".utf8)))
            "What's this?"
        })
    } throws: { error in
        guard case LanguageModelError.unsupportedTranscriptContent(let context) = error,
              case .prompt = context.unsupportedContent.first
        else { return false }
        return true
    }
    #expect(model.requests.isEmpty)
    #expect(session.transcript.isEmpty)
    #expect(!session.isResponding)
}

@Test func modelsSupportNoFilesUnlessTheySaySo() async throws {
    #expect(try await SystemLanguageModel.default.supportsDataAttachmentType(.pdf) == false)
}

@Test func aFileKeepsATypeThisCopyDoesntKnow() throws {
    let json = Data(#"{"type":"data","data":{"contentType":"public.plain-text","content":"aGk="}}"#.utf8)
    let attachment = try JSONDecoder().decode(Transcript.Attachment.self, from: json)
    guard case .data(let data) = attachment else {
        Issue.record("Not a data attachment")
        return
    }
    #expect(data.contentType.identifier == "public.plain-text")
    #expect(data.content == Data("hi".utf8))
    let encoded = try JSONEncoder().encode(attachment)
    #expect(String(decoding: encoded, as: UTF8.self).contains(#""contentType":"public.plain-text""#))
    #expect(try JSONDecoder().decode(Transcript.Attachment.self, from: encoded) == attachment)
}

@Test func typesAreFoundByTheirMIMEType() {
    #expect(UTType(mimeType: "application/pdf") == .pdf)
    #expect(UTType(mimeType: "Application/PDF; charset=binary") == .pdf)
    #expect(UTType(mimeType: "text/plain") == nil)
    #expect(UTType("com.adobe.pdf") == .pdf)
    #expect(UTType.pdf.preferredMIMEType == "application/pdf")
    #expect(UTType.pdf.conforms(to: .data))
    #expect(UTType.pdf.conforms(to: .pdf))
    #expect(!UTType.data.conforms(to: .pdf))
}
