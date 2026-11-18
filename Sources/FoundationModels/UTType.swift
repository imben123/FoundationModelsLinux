import Foundation

/// A type of file, standing in for `UniformTypeIdentifiers`' `UTType`, which only Apple's platforms
/// have, for the types of ``Transcript/DataAttachment``.
///
/// It only knows the types its users send, with the parts of Apple's API they call. Apple's is in
/// its own module, so code that names it imports `UniformTypeIdentifiers` only where that exists,
/// and the rest of it is the same on either.
public struct UTType: Sendable, Hashable, CustomStringConvertible {
    /// The type's identifier, such as `com.adobe.pdf`.
    public let identifier: String
    /// Its MIME types, the preferred one first.
    let mimeTypes: [String]
    /// The identifiers of the types it conforms to, other than itself, nearest first.
    let supertypes: [String]

    init(identifier: String, mimeTypes: [String] = [], supertypes: [String] = []) {
        self.identifier = identifier
        self.mimeTypes = mimeTypes
        self.supertypes = supertypes
    }

    /// The base type of bytes, which every type here conforms to.
    public static let data = UTType(identifier: "public.data", supertypes: ["public.item"])
    /// A PDF.
    public static let pdf = UTType(identifier: "com.adobe.pdf", mimeTypes: ["application/pdf"], supertypes: ["public.data", "public.item"])

    static let known: [UTType] = [.data, .pdf]

    /// The known type with `identifier`, or `nil`, as Apple's gives for an undeclared one.
    public init?(_ identifier: String) {
        guard let type = Self.known.first(where: { $0.identifier == identifier }) else { return nil }
        self = type
    }

    /// The known type with `mimeType`, ignoring case and any parameters, or `nil`.
    public init?(mimeType: String) {
        let mimeType = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard let type = Self.known.first(where: { $0.mimeTypes.contains(mimeType) }) else { return nil }
        self = type
    }

    /// The type's MIME type, if it has one.
    public var preferredMIMEType: String? { mimeTypes.first }

    /// Whether the type is `type` or one of its subtypes.
    public func conforms(to type: UTType) -> Bool {
        type.identifier == identifier || supertypes.contains(type.identifier)
    }

    public var description: String { identifier }

    /// A type only known by its identifier, such as one decoded from a transcript that a later
    /// version wrote, which keeps it as it was.
    static func named(_ identifier: String) -> UTType {
        UTType(identifier) ?? UTType(identifier: identifier)
    }

    public static func == (lhs: UTType, rhs: UTType) -> Bool { lhs.identifier == rhs.identifier }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}
