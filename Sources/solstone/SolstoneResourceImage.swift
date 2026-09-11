// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation

nonisolated enum SolstoneResourceImage {
    static let supportedTypes: Set<String> = ["icns", "pdf", "png"]
    static let defaultTypes: [String] = ["icns", "pdf", "png"]

    enum LoadError: Error, Equatable, CustomStringConvertible, Sendable {
        case notFound(name: String, directory: String, types: [String])
        case unreadable(path: String)
        case emptyRepresentation(path: String)
        case unsupportedType(type: String)

        var description: String {
            switch self {
            case .notFound(let name, let directory, let types):
                return "resource '\(name)' not found in directory '\(directory)' for types \(types)"
            case .unreadable(let path):
                return "resource at path '\(path)' could not be read as an image"
            case .emptyRepresentation(let path):
                return "resource at path '\(path)' has empty representations"
            case .unsupportedType(let type):
                return "unsupported image type '\(type)'; must be one of \(SolstoneResourceImage.supportedTypes.sorted())"
            }
        }
    }

    static func load(
        named name: String,
        in bundle: Bundle,
        inDirectory directory: String = "Resources",
        types: [String] = defaultTypes,
        isTemplate: Bool = false
    ) throws -> NSImage {
        for type in types {
            guard supportedTypes.contains(type) else {
                throw LoadError.unsupportedType(type: type)
            }
        }

        var foundPath: String?
        for type in types {
            if let path = bundle.path(forResource: name, ofType: type, inDirectory: directory) {
                foundPath = path
                break
            }
        }

        guard let path = foundPath else {
            throw LoadError.notFound(name: name, directory: directory, types: types)
        }

        guard let image = NSImage(contentsOfFile: path) else {
            throw LoadError.unreadable(path: path)
        }

        guard !image.representations.isEmpty else {
            throw LoadError.emptyRepresentation(path: path)
        }

        image.isTemplate = isTemplate

        return image
    }

    static func mustLoad(
        named name: String,
        in bundle: Bundle,
        inDirectory directory: String = "Resources",
        types: [String] = defaultTypes,
        isTemplate: Bool = false
    ) -> NSImage {
        do {
            return try load(
                named: name,
                in: bundle,
                inDirectory: directory,
                types: types,
                isTemplate: isTemplate
            )
        } catch {
            preconditionFailure("SolstoneResourceImage.mustLoad failed: \(error)")
        }
    }
}
