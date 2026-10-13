import Foundation

/// Pulls JSON out of free-form model output (code fences, leading prose, trailing commentary).
public enum JSONExtraction {
    /// Returns the first balanced, valid top-level JSON object found in `text`, or `nil`.
    public static func extractObject(from text: String) -> Data? {
        let bytes = Array(text.utf8)
        var searchFrom = 0
        while let start = bytes[searchFrom...].firstIndex(of: UInt8(ascii: "{")) {
            if let end = matchingBrace(in: bytes, from: start) {
                let candidate = Data(bytes[start...end])
                if (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] {
                    return candidate
                }
            }
            searchFrom = start + 1
        }
        return nil
    }

    /// Index of the `}` closing the object that opens at `start`, honouring JSON strings and escapes.
    private static func matchingBrace(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}

/// Decodes the first JSON object embedded in model output.
public func decodeJSON<T: Decodable>(_ type: T.Type, from text: String, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    guard let data = JSONExtraction.extractObject(from: text) else {
        throw LLMError.invalidResponse("No JSON object found in model output: \(text.prefix(200))")
    }
    do {
        return try decoder.decode(T.self, from: data)
    } catch {
        throw LLMError.invalidResponse("JSON did not match \(T.self): \(error)")
    }
}

/// Instruction appended to prompts when a provider has no native JSON mode (or needs the word "JSON" in the prompt).
enum PromptSnippets {
    static let jsonOnly = "Respond with a single valid JSON object only. Do not wrap it in Markdown code fences and do not add any text before or after it."
}
