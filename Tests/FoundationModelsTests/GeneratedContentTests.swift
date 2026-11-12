import Foundation
import FoundationModels
import Testing

@Test(arguments: [
    #"{"query":"swift","limit":3,"nested":{"b":[1,2.5,true,null],"a":"x"}}"#,
    #"[]"#,
    #"{}"#,
    #""line\nbreak \"quoted\" \\ é 😀""#,
    #"-1.5e-7"#,
])
func jsonIsWrittenBackAsItWasRead(json: String) throws {
    let content = try GeneratedContent(json: json)

    #expect(try GeneratedContent(json: content.jsonString).jsonString == content.jsonString)
    #expect(try GeneratedContent(json: content.jsonString) == content)
}

@Test func keysKeepTheirOrderAndOutputIsCompact() throws {
    let content = try GeneratedContent(json: #"{ "z" : 1, "a" : [ 1 , 2 ], "m" : "x" }"#)

    #expect(content.jsonString == #"{"z":1,"a":[1,2],"m":"x"}"#)
}

@Test func escapesAreRead() throws {
    let content = try GeneratedContent(json: #""aé😀\/\t""#)

    #expect(try content.value(String.self) == "aé😀/\t")
}

@Test(arguments: ["", "{", #"{"a"}"#, "[1,]", "tru", #""unterminated"#, "1 2", "01x"])
func malformedJSONThrows(json: String) {
    #expect(throws: LanguageModelSession.GenerationError.self) {
        try GeneratedContent(json: json)
    }
}

@Test func propertiesAreReadByType() throws {
    let content = try GeneratedContent(json: #"{"name":"Ada","age":36,"tags":["a","b"],"note":null}"#)

    #expect(try content.value(String.self, forProperty: "name") == "Ada")
    #expect(try content.value(Int.self, forProperty: "age") == 36)
    #expect(try content.value([String].self, forProperty: "tags") == ["a", "b"])
    #expect(try content.value(String?.self, forProperty: "note") == nil)
    #expect(try content.value(String?.self, forProperty: "missing") == nil)
    #expect(throws: LanguageModelSession.GenerationError.self) {
        try content.value(String.self, forProperty: "missing")
    }
    #expect(throws: LanguageModelSession.GenerationError.self) {
        try content.value(Int.self, forProperty: "name")
    }
}

@Test func contentMadeFromValuesKeepsTheirOrder() {
    let content = GeneratedContent(properties: ["b": "x", "a": 2, "c": [true, false]])

    #expect(content.jsonString == #"{"b":"x","a":2,"c":[true,false]}"#)
    #expect(GeneratedContent("text").jsonString == #""text""#)
}

@Test func contentCodesAsItsJSON() throws {
    let content = try GeneratedContent(json: #"{"b":1,"a":2}"#)

    let decoded = try JSONDecoder().decode(GeneratedContent.self, from: JSONEncoder().encode(content))

    #expect(decoded.jsonString == #"{"b":1,"a":2}"#)
}
