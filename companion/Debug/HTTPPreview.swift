import Foundation

/// Turns raw requests into readable, safe previews.
nonisolated enum HTTPPreview {
    static let mask = "••••••••"
    /// Header and query names whose values are secrets.
    private static let secretNames: Set<String> = ["authorization", "x-goog-api-key", "key", "api-key", "x-api-key"]
    /// Base64 strings shorter than this are shown as is.
    private static let minimumMediaLength = 256
    /// Longest text body kept for non-JSON content.
    static let maxTextLength = 20_000

    static func service(for url: URL?) -> String {
        guard let url else { return "Unknown" }
        let host = url.host() ?? ""
        if host.contains("googleapis.com") || url.path().contains(":generateContent") { return "Gemini" }
        if host.contains("openrouter") { return "OpenRouter" }
        if url.path().hasSuffix("/asr") { return "Whisper" }
        if url.path().hasPrefix("/api/") { return "Ollama" }
        return host.isEmpty ? "Unknown" : host
    }

    static func redactedURL(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url?.absoluteString ?? ""
        }
        components.queryItems = components.queryItems?.map {
            secretNames.contains($0.name.lowercased()) ? URLQueryItem(name: $0.name, value: mask) : $0
        }
        return components.string ?? url.absoluteString
    }

    static func redactedHeaders(_ headers: [String: String]) -> [(name: String, value: String)] {
        headers
            .map { (name: $0.key, value: secretNames.contains($0.key.lowercased()) ? mask : $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Readable body: pretty JSON or multipart text with media collapsed into placeholders.
    static func body(_ data: Data, contentType: String?) -> String {
        guard !data.isEmpty else { return "" }
        let type = contentType?.lowercased() ?? ""

        if type.hasPrefix("multipart/"), let boundary = boundary(from: contentType ?? "") {
            return multipart(data, boundary: boundary)
        }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(
               withJSONObject: collapsingMedia(in: object),
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
           ) {
            return String(decoding: pretty, as: UTF8.self)
        }
        if type.hasPrefix("audio/") || type.hasPrefix("video/") || type.hasPrefix("image/") {
            return placeholder(mimeType: type, byteCount: data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return placeholder(mimeType: type.isEmpty ? "binary" : type, byteCount: data.count)
        }
        return text.count > maxTextLength ? String(text.prefix(maxTextLength)) + "\n… (truncated)" : text
    }

    static func placeholder(mimeType: String, byteCount: Int) -> String {
        "<\(mimeType) · \(Int64(byteCount).formatted(.byteCount(style: .file)))>"
    }

    /// Replaces base64 media strings (bare or `data:` URLs) with placeholders, keeping everything else.
    static func collapsingMedia(in object: Any) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            // A sibling key tells which kind of media a base64 string holds.
            let mimeType = (dictionary["mimeType"] ?? dictionary["mime_type"]) as? String
                ?? (dictionary["format"] as? String).map { "audio/\($0)" }
            return dictionary.mapValues { value -> Any in
                if let string = value as? String, let collapsed = collapsedMedia(string, mimeType: mimeType) {
                    return collapsed
                }
                return collapsingMedia(in: value)
            }
        case let array as [Any]:
            return array.map(collapsingMedia(in:))
        case let string as String:
            return collapsedMedia(string, mimeType: nil) ?? string
        default:
            return object
        }
    }

    private static func collapsedMedia(_ string: String, mimeType: String?) -> String? {
        if string.hasPrefix("data:"), let range = string.range(of: ";base64,") {
            let type = String(string[string.index(string.startIndex, offsetBy: 5)..<range.lowerBound])
            return placeholder(mimeType: type, byteCount: string[range.upperBound...].count * 3 / 4)
        }
        guard string.count >= minimumMediaLength, isBase64(string) else { return nil }
        return placeholder(mimeType: mimeType ?? "base64", byteCount: string.count * 3 / 4)
    }

    private static func isBase64(_ string: String) -> Bool {
        string.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == 43 || byte == 47 || byte == 61  // + / =
        }
    }

    private static func boundary(from contentType: String) -> String? {
        contentType
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("boundary=") }
            .map { String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    /// Shows each part's headers; text parts keep their content, binary parts become placeholders.
    private static func multipart(_ data: Data, boundary: String) -> String {
        let delimiter = Data("--\(boundary)".utf8)
        let separator = Data("\r\n\r\n".utf8)
        var output: [String] = []
        var searchStart = data.startIndex

        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            let partStart = range.upperBound
            let next = data.range(of: delimiter, in: partStart..<data.endIndex)
            guard let next else {
                output.append("--\(boundary)--")
                break
            }
            output.append("--\(boundary)")
            let part = data[partStart..<next.lowerBound]
            if let headerEnd = part.range(of: separator) {
                let headers = String(decoding: part[part.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var content = part[headerEnd.upperBound...]
                if content.suffix(2) == Data("\r\n".utf8) { content = content.dropLast(2) }

                let partType = headers
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-type:") }
                    .map { $0.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces) }
                output.append(headers)
                output.append("")
                if let partType, !partType.hasPrefix("text/"), !partType.contains("json") {
                    output.append(placeholder(mimeType: partType, byteCount: content.count))
                } else {
                    output.append(String(decoding: content, as: UTF8.self))
                }
            }
            searchStart = next.lowerBound
        }
        return output.joined(separator: "\n")
    }
}
