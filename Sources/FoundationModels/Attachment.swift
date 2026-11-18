import Foundation

extension Transcript {
    /// Something other than text in a prompt, such as an image.
    public struct AttachmentSegment: Sendable, Equatable, Identifiable, Codable, CustomStringConvertible {
        public var id: String
        public var content: Attachment
        public var label: String?

        public init(id: String = UUID().uuidString, content: Attachment, label: String? = nil) {
            self.id = id
            self.content = content
            self.label = label
        }

        public var description: String {
            switch content {
            case .image(let image): "Image(\(image.mediaType), \(image.data.count) bytes)"
            }
        }
    }

    public enum Attachment: Sendable, Equatable, Codable {
        case image(ImageAttachment)

        private enum CodingKeys: String, CodingKey {
            case type, image
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "image": self = .image(try container.decode(ImageAttachment.self, forKey: .image))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown attachment \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let image):
                try container.encode("image", forKey: .type)
                try container.encode(image, forKey: .image)
            }
        }
    }

    /// An image, as its encoded bytes.
    ///
    /// Apple's holds a decoded image, made from a `CGImage` and read back as one, and there's no
    /// CoreGraphics here. So this one is made from, and gives back, the bytes of a file in a format
    /// a model reads, such as JPEG or PNG, which it doesn't check or decode.
    public struct ImageAttachment: Sendable, Equatable, Codable {
        /// The encoded image.
        public var data: Data
        /// Its media type, such as `image/jpeg`.
        public var mediaType: String

        public init(data: Data, mediaType: String) {
            self.data = data
            self.mediaType = mediaType
        }
    }
}

/// What an ``Attachment`` holds when it's an image.
public struct ImageAttachmentContent: Sendable, Equatable {
    let image: Transcript.ImageAttachment
}

/// Something other than text to put in a prompt, such as an image.
public struct Attachment<Content> {
    let segment: Transcript.AttachmentSegment

    public func label(_ label: String) -> Attachment<Content> {
        var segment = segment
        segment.label = label
        return Attachment(segment: segment)
    }
}

extension Attachment where Content == ImageAttachmentContent {
    /// An image from its encoded bytes, in place of Apple's initializers, which take decoded ones.
    /// See ``Transcript/ImageAttachment``.
    public init(data: Data, mediaType: String) {
        self.init(segment: Transcript.AttachmentSegment(content: .image(.init(data: data, mediaType: mediaType))))
    }
}

extension Attachment: PromptRepresentable {
    public var promptRepresentation: Prompt {
        Prompt(parts: [.attachment(segment)])
    }
}
