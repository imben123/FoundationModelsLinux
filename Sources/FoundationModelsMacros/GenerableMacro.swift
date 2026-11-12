import Foundation
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct FoundationModelsMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [GenerableMacro.self, GuideMacro.self]
}

struct MacroError: Error, CustomStringConvertible {
    let description: String
}

/// Generates nothing. `@Generable` reads it.
public struct GuideMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(VariableDeclSyntax.self) else {
            throw MacroError(description: "@Guide only applies to properties")
        }
        return []
    }
}

/// Conforms a struct or an enum without associated values to `Generable`.
public struct GenerableMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let description = argument(labeled: "description", in: node) ?? "nil"
        let access = accessLevel(of: declaration)
        let members: String
        if declaration.is(StructDeclSyntax.self) {
            members = try structMembers(of: declaration, description: description, access: access)
        } else if declaration.is(EnumDeclSyntax.self) {
            members = try enumMembers(of: declaration, description: description, access: access)
        } else {
            throw MacroError(description: "@Generable only applies to structs and enums")
        }
        let conformance = protocols.isEmpty ? "" : ": FoundationModels.Generable"
        let source: DeclSyntax = """
            extension \(type.trimmed)\(raw: conformance) {
            \(raw: members)
            }
            """
        guard let decl = source.as(ExtensionDeclSyntax.self) else {
            throw MacroError(description: "@Generable couldn't generate its extension")
        }
        return [decl]
    }

    /// A stored property the model generates.
    private struct Property {
        let name: String
        let type: String
        let description: String
        let guides: String
    }

    private static func structMembers(of declaration: some DeclGroupSyntax, description: String, access: String) throws -> String {
        let properties = try storedProperties(of: declaration)
        let schemaProperties = properties.map { property in
            """
                        FoundationModels.GenerationSchema.Property(\
            name: \(literal(raw(property.name))), \
            description: \(property.description), \
            type: \(property.type).self, \
            guides: [\(property.guides)])
            """
        }
        let decoding = properties.map { property in
            "        self.\(property.name) = try content.value(\(property.type).self, forProperty: \(literal(raw(property.name))))"
        }
        let encoding = properties.isEmpty
            ? ":"
            : properties.map { "\(literal(raw($0.name))): self.\($0.name)" }.joined(separator: ", ")
        return """
                \(access)static var generationSchema: FoundationModels.GenerationSchema {
                    FoundationModels.GenerationSchema(type: Self.self, description: \(description), properties: [
            \(schemaProperties.joined(separator: ",\n"))
                    ])
                }

                \(access)init(_ content: FoundationModels.GeneratedContent) throws {
            \(decoding.joined(separator: "\n"))
                }

                \(access)var generatedContent: FoundationModels.GeneratedContent {
                    FoundationModels.GeneratedContent(properties: [\(encoding)])
                }
            """
    }

    private static func enumMembers(of declaration: some DeclGroupSyntax, description: String, access: String) throws -> String {
        var cases: [String] = []
        for member in declaration.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                guard element.parameterClause == nil else {
                    throw MacroError(description: "@Generable only applies to enums without associated values")
                }
                cases.append(element.name.text)
            }
        }
        let names = cases.map { literal(raw($0)) }
        let decoding = cases.map { "        case \(literal(raw($0))): self = .\($0)" }
        let encoding = cases.map { "        case .\($0): FoundationModels.GeneratedContent(\(literal(raw($0))))" }
        return """
                \(access)static var generationSchema: FoundationModels.GenerationSchema {
                    FoundationModels.GenerationSchema(type: Self.self, description: \(description), anyOf: [\(names.joined(separator: ", "))])
                }

                \(access)init(_ content: FoundationModels.GeneratedContent) throws {
                    let value = try content.value(String.self)
                    switch value {
            \(decoding.joined(separator: "\n"))
                    default:
                        throw FoundationModels.LanguageModelSession.GenerationError.decodingFailure(
                            .init(debugDescription: "\\(value) isn't a case of \\(Self.self)")
                        )
                    }
                }

                \(access)var generatedContent: FoundationModels.GeneratedContent {
                    switch self {
            \(encoding.joined(separator: "\n"))
                    }
                }
            """
    }

    /// Skips static and computed properties, and a `let` that has its value.
    private static func storedProperties(of declaration: some DeclGroupSyntax) throws -> [Property] {
        var properties: [Property] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isStatic = variable.modifiers.contains { ["static", "class"].contains($0.name.text) }
            guard !isStatic else { continue }
            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
            let guide = variable.attributes.compactMap { attribute -> AttributeSyntax? in
                guard let attribute = attribute.as(AttributeSyntax.self),
                      attribute.attributeName.trimmedDescription == "Guide"
                else { return nil }
                return attribute
            }.first
            for binding in variable.bindings {
                if let accessors = binding.accessorBlock, isComputed(accessors) { continue }
                if isLet, binding.initializer != nil { continue }
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    throw MacroError(description: "@Generable needs each property to have a name of its own")
                }
                guard let type = binding.typeAnnotation?.type.trimmedDescription else {
                    throw MacroError(description: "@Generable needs the type of \(name) to be written")
                }
                properties.append(Property(
                    name: name,
                    type: type,
                    description: guide.flatMap { argument(labeled: "description", in: $0) } ?? "nil",
                    guides: guide.map(unlabeledArguments(in:)) ?? ""
                ))
            }
        }
        return properties
    }

    /// Observers like `didSet` still store, unlike a getter.
    private static func isComputed(_ accessors: AccessorBlockSyntax) -> Bool {
        switch accessors.accessors {
        case .getter:
            return true
        case .accessors(let list):
            return list.contains { ["get", "set", "_read", "_modify", "unsafeAddress"].contains($0.accessorSpecifier.text) }
        }
    }

    private static func argument(labeled label: String, in attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments else { return nil }
        return arguments.first { $0.label?.text == label }?.expression.trimmedDescription
    }

    private static func unlabeledArguments(in attribute: AttributeSyntax) -> String {
        guard case .argumentList(let arguments) = attribute.arguments else { return "" }
        return arguments.filter { $0.label == nil }.map(\.expression.trimmedDescription).joined(separator: ", ")
    }

    /// `public ` for a public type, whose conformance has to be public too.
    private static func accessLevel(of declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.text {
            case "public", "open": return "public "
            case "package": return "package "
            default: continue
            }
        }
        return ""
    }

    /// A name without the backticks that let it be a keyword.
    private static func raw(_ name: String) -> String {
        name.hasPrefix("`") && name.hasSuffix("`") ? String(name.dropFirst().dropLast()) : name
    }

    private static func literal(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
