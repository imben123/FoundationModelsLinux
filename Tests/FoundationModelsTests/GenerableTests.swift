import Foundation
import FoundationModels
import Testing

@Generable(description: "Someone to write to")
struct Contact {
    @Guide(description: "Their full name")
    var name: String
    @Guide(description: "Their age in years", .range(0...150))
    var age: Int
    var nickname: String?
    @Guide(description: "Ways to reach them", GenerationGuide<[String]>.maximumCount(3))
    var emails: [String]
    /// Not generated: it has its value.
    let kind = "contact"
    /// Not generated: it's computed.
    var greeting: String { "Hi \(name)" }
    static let example = "Ada"
}

@Generable
enum Mood {
    case happy
    case `default`
}

/// The bytes a provider is sent, with sorted keys, as AgentKit's gateway client sends them.
private func sortedJSON(_ schema: GenerationSchema) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(schema), as: UTF8.self)
}

@Test func aStructsSchemaListsItsStoredProperties() throws {
    #expect(try sortedJSON(Contact.generationSchema) == #"""
        {"additionalProperties":false,"description":"Someone to write to",\#
        "properties":{\#
        "age":{"description":"Their age in years","maximum":150,"minimum":0,"type":"integer"},\#
        "emails":{"description":"Ways to reach them","items":{"type":"string"},"maxItems":3,"type":"array"},\#
        "name":{"description":"Their full name","type":"string"},\#
        "nickname":{"type":"string"}},\#
        "required":["name","age","emails"],"title":"Contact","type":"object",\#
        "x-order":["name","age","nickname","emails"]}
        """#)
}

@Test func aStructIsReadAndWrittenAsContent() throws {
    let content = try GeneratedContent(json: #"{"name":"Ada","age":36,"emails":["ada@example.com"]}"#)

    let contact = try Contact(content)

    #expect(contact.name == "Ada")
    #expect(contact.age == 36)
    #expect(contact.nickname == nil)
    #expect(contact.emails == ["ada@example.com"])
    #expect(contact.generatedContent.jsonString == #"{"name":"Ada","age":36,"nickname":null,"emails":["ada@example.com"]}"#)
    #expect(throws: LanguageModelSession.GenerationError.self) {
        try Contact(GeneratedContent(json: #"{"name":"Ada"}"#))
    }
}

@Test func anEnumIsOneOfItsCases() throws {
    #expect(try sortedJSON(Mood.generationSchema) == #"{"enum":["happy","default"],"title":"Mood","type":"string"}"#)
    #expect(try Mood(GeneratedContent("default")) == .default)
    #expect(Mood.happy.generatedContent.jsonString == #""happy""#)
    #expect(throws: LanguageModelSession.GenerationError.self) {
        try Mood(GeneratedContent("sad"))
    }
}
