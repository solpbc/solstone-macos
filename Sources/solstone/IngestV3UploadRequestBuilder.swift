// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct PreparedIngestV3Upload: Sendable {
    let request: URLRequest
    let bodyURL: URL
}

/// Builds the v3 multipart request independently from HTTP. The caller owns the
/// returned body file and removes it after URLSession finishes reading it.
struct IngestV3UploadRequestBuilder {
    struct SubmittedFile: Codable, Sendable, Equatable {
        let submitted: String
    }

    private struct Envelope: Codable, Sendable, Equatable {
        let day: String
        let segment: String
        let files: [SubmittedFile]
        let meta: [String: IngestJSONValue]?
    }

    static func build(
        baseURL: String,
        day: String,
        segment: String,
        selectedFiles: [URL],
        meta: [String: IngestJSONValue]?,
        boundary: String,
        bodyURL: URL
    ) throws -> PreparedIngestV3Upload {
        guard !selectedFiles.isEmpty else { throw UploadError.noFiles }
        guard selectedFiles.count <= IngestProtocolV3.maxFiles else { throw UploadError.invalidRequest }
        guard let url = URL(string: "\(baseURL)\(IngestProtocolV3.uploadPath)") else {
            throw UploadError.invalidURL
        }

        let envelope = Envelope(
            day: day,
            segment: segment,
            files: selectedFiles.map { SubmittedFile(submitted: $0.lastPathComponent) },
            meta: meta
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        guard let envelopeString = String(data: envelopeData, encoding: .utf8) else {
            throw UploadError.invalidResponse
        }
        guard envelopeData.count <= IngestProtocolV3.maxPartBytes else {
            throw UploadError.invalidRequest
        }

        var fileBytes = 0
        for file in selectedFiles {
            let filenameBytes = file.lastPathComponent.lengthOfBytes(using: .utf8)
            guard filenameBytes <= IngestProtocolV3.maxFilenameBytes,
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 0,
                  size <= IngestProtocolV3.maxPartBytes else {
                throw UploadError.invalidRequest
            }
            fileBytes += size
        }
        // The multipart framing itself consumes bytes too, so equality is not safe.
        guard fileBytes + envelopeData.count < IngestProtocolV3.maxConnectionBodyBytes else {
            throw UploadError.invalidRequest
        }

        let fileManager = FileManager.default
        fileManager.createFile(atPath: bodyURL.path, contents: nil)
        let bodyHandle = try FileHandle(forWritingTo: bodyURL)
        defer { try? bodyHandle.close() }

        try bodyHandle.writeMultipartField(boundary: boundary, name: "envelope", value: envelopeString)
        for fileURL in selectedFiles {
            let filename = fileURL.lastPathComponent
            let mimeType = fileURL.pathExtension == "mp4" ? "video/mp4" : "audio/mp4"
            try bodyHandle.writeMultipartFileHeader(
                boundary: boundary,
                name: "files",
                filename: filename,
                mimeType: mimeType
            )

            let sourceHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? sourceHandle.close() }
            while true {
                let chunk = sourceHandle.readData(ofLength: 1_024 * 1_024)
                if chunk.isEmpty { break }
                try bodyHandle.write(contentsOf: chunk)
            }
            try bodyHandle.write(contentsOf: Data("\r\n".utf8))
        }
        try bodyHandle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        try bodyHandle.synchronize()
        guard let bodySize = try? bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bodySize <= IngestProtocolV3.maxConnectionBodyBytes else {
            throw UploadError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(IngestProtocolV3.headerValue, forHTTPHeaderField: IngestProtocolV3.headerName)
        return PreparedIngestV3Upload(request: request, bodyURL: bodyURL)
    }
}

private extension FileHandle {
    func writeMultipartField(boundary: String, name: String, value: String) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        try write(contentsOf: Data(header.utf8))
    }

    func writeMultipartFileHeader(
        boundary: String,
        name: String,
        filename: String,
        mimeType: String
    ) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        try write(contentsOf: Data(header.utf8))
    }
}
