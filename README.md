# FoundationModelsLinux

A copy of the parts of Apple's [FoundationModels](https://developer.apple.com/documentation/foundationmodels)
that [AgentKit](https://github.com/imben123/AgentKitApp) and its
[fork of ClaudeForFoundationModels](https://github.com/imben123/ClaudeForFoundationModels) use,
for platforms that don't have Apple's, such as Linux. Its product is a module named
`FoundationModels`, so `import FoundationModels` and `#if canImport(FoundationModels)` work
unchanged. Depend on it only where Apple's isn't:

```swift
#if !canImport(Darwin)
dependencies.append(.package(url: "https://github.com/imben123/FoundationModelsLinux", exact: "0.3.0"))
#endif
```

It needs Swift 6.4 or later.

## What it is

- It copies only the API that its users need, with Apple's names and signatures, so the same code
  compiles against either. When a user starts using more of Apple's API, add it here with the same
  shape. Apple's `.swiftinterface`, in the macOS SDK at
  `System/Library/Frameworks/FoundationModels.framework`, is the reference.
- `@Generable` and `@Guide` are macros in `FoundationModelsMacros`. A guide on an array property
  names its type, as `GenerationGuide<[String]>.maximumCount(3)`, because a macro's arguments are
  checked without the property's type.
- `GeneratedContent` keeps the order of keys and writes compact JSON, so tool arguments read back
  from a saved chat are sent exactly as they were. Apple's adds spaces after colons.
  `GenerationSchema` encodes as the JSON Schema Apple's does, with `x-order`.
- `LanguageModelSession` runs the tool loop. Each request's text goes into reasoning and response
  entries in the order it arrives, its tool calls become one `toolCalls` entry, then the tools run
  and the next request follows. A stream waits for each snapshot to be taken before going on.
- An executor's event can name the entry it adds to with an `entryID`, as Apple's sessions allow.
  The session starts an entry with that ID the first time text, a signature, metadata or a tool
  call names it, and entries go in the order they start. Usage alone starts no entry.
  `updateMetadata` merges into the entry, or the tool call, it names. Tool calls that name an entry
  are in the transcript as they arrive, with empty arguments until they're JSON. Events without an
  `entryID` add to the entry of their kind that's being written. ClaudeForFoundationModels relies
  on all of this, and AgentKit's `aSessionKeepsClaudesEntriesAsApplesDoes` checks it against Apple's
  session.
- A prompt can hold images, as `Attachment` and `.attachment` segments, before or between its
  text. There's no CoreGraphics here, so in place of Apple's `CGImage` initializers and
  `cgImage`, an image is made from its encoded bytes and media type, with
  `Attachment(data:mediaType:)` and `Transcript.ImageAttachment(data:mediaType:)`, and gives them
  back as `data` and `mediaType`, unchecked and undecoded. A prompt's text between attachments
  becomes one segment, with its parts on lines of their own.
- A prompt can also hold files, such as PDFs, as `Transcript.DataAttachment`s of their type and
  bytes, made with `Attachment(_:)` from a `DataAttachmentRepresentable`. A data attachment is
  already bytes in Apple's framework, so only its type needs a stand-in: `UTType` here knows
  `.pdf` and `.data`, with `identifier`, `preferredMIMEType`, `init?(_:)`, `init?(mimeType:)`
  and `conforms(to:)`. Apple's is in `UniformTypeIdentifiers`, so code that names it imports that
  only where it exists. A model reads none unless its `supportsDataAttachmentType(_:)` says so,
  and a session refuses a prompt with any other, before it's added to the transcript, with
  `LanguageModelError.unsupportedTranscriptContent`. A type this copy doesn't know is kept by its
  identifier when a transcript is decoded.
- `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` report that they're unavailable, so
  only custom models (a `LanguageModel` with its own executor) answer.
- The custom-model API (`LanguageModelExecutor`, its request and channel) is reconstructed from how
  AgentKit's gateway executor and ClaudeForFoundationModels use it, so it may differ from Apple's where
  neither touches it.
- Switches over `Transcript.Entry` and `Transcript.Segment` with a `default` warn here, because this
  copy has no cases beyond the ones its users handle.

When Apple publishes its open-source FoundationModels, depend on that instead.

## Development

`swift test`, on Linux. On macOS, Apple's framework has the same module name, so build and test in
a container: `docker run --rm -v "$PWD":/w -w /w swift:6.4-noble swift test`.
