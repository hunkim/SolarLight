import Foundation

/// Calls the Upstage Responses API with the `file_search` tool to produce a
/// synthesized answer grounded in the user's vector store.
///
/// Endpoint: POST https://api.upstage.ai/v2/responses
/// Body: { model, input, tools: [{ type: "file_search", vector_store_ids }] }
struct RAGClient {
    static let defaultBaseURL = "https://api.upstage.ai/v2"
    static let defaultModel = "solar-pro3"

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case badResponse(Int, String?)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Upstage API key is not configured."
            case .invalidURL: return "Upstage base URL is not valid."
            case .badResponse(let status, let detail):
                if let detail, !detail.isEmpty {
                    return "Upstage API returned HTTP \(status): \(detail)"
                }
                return "Upstage API returned HTTP \(status)."
            case .decoding(let message):
                return "Failed to decode Responses output: \(message)"
            }
        }
    }

    /// Citation drawn from `file_citation` annotations in the response.
    struct FileCitation: Equatable {
        let fileId: String
        let filename: String
        let quote: String?
    }

    struct SynthesizedAnswer {
        let text: String
        let citations: [FileCitation]
    }

    let apiKey: String
    let baseURL: String
    let model: String

    init(
        apiKey: String,
        baseURL: String = RAGClient.defaultBaseURL,
        model: String = RAGClient.defaultModel
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    func synthesize(query: String, vectorStoreId: String) async throws -> SynthesizedAnswer {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }
        guard let url = URL(string: baseURL)?.appending(path: "responses") else {
            throw ClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // The system instruction does two things:
        //   1. Suppresses reasoning/planning leakage — solar-pro3 sometimes
        //      writes its plan ("The user asked X, so I will...") into the
        //      visible output without this guard.
        //   2. Pins the citation format to `[N]` so our inline filename
        //      renderer has something to substitute against.
        let instructions = """
        You answer the user's query using the file_search tool.

        Strict output rules:
        - Output only the final answer to the user. No preamble, no planning, no "the user asked", no meta-commentary about citations.
        - Match the language of the user's query.
        - Use Markdown: short paragraphs and bullets when listing.
        - Cite sources as [1], [2], ... numbered in the order you first reference them. Only cite indices that correspond to real retrieved files; do not invent citation numbers.
        - Be concise. If the retrieved files don't contain a clear answer, say so briefly rather than padding.
        """

        let payload: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": query,
            // Keep reasoning effort minimal: we want a direct cited answer,
            // not a chain-of-thought walkthrough leaking into the output.
            "reasoning": [
                "effort": "low"
            ],
            "tools": [
                [
                    "type": "file_search",
                    "vector_store_ids": [vectorStoreId]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8)?.prefix(500).description
            throw ClientError.badResponse(http.statusCode, detail)
        }

        return try parse(data: data)
    }

    // MARK: - Parsing

    /// Parses an OpenAI-style Responses API payload. The exact shape can vary
    /// slightly across SDK versions, so we try the most common arrangements
    /// and fall back to a flattened text scan.
    private func parse(data: Data) throws -> SynthesizedAnswer {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.decoding("Top-level payload is not a JSON object.")
        }

        // Preferred shape: output[].content[].text + annotations.
        // Prefer message-type items so reasoning/tool_call blocks (when the
        // API emits them as siblings) don't leak into the visible answer.
        if let output = json["output"] as? [[String: Any]] {
            let messageItems = output.filter { ($0["type"] as? String) == "message" }
            let candidates = messageItems.isEmpty ? output : messageItems

            for item in candidates {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        let type = part["type"] as? String ?? ""
                        if type == "output_text" || type == "text" || part["text"] != nil {
                            let text = (part["text"] as? String) ?? extractText(from: part) ?? ""
                            let citations = parseAnnotations(part["annotations"] as? [[String: Any]])
                            if !text.isEmpty {
                                return SynthesizedAnswer(text: text, citations: citations)
                            }
                        }
                    }
                }
            }
        }

        // Convenience field some SDKs add.
        if let text = json["output_text"] as? String, !text.isEmpty {
            return SynthesizedAnswer(text: text, citations: [])
        }

        // String-shaped output (rare but the docs example just prints it).
        if let text = json["output"] as? String, !text.isEmpty {
            return SynthesizedAnswer(text: text, citations: [])
        }

        // Last-ditch: any "text" string anywhere in the payload.
        if let text = findFirstText(in: json), !text.isEmpty {
            return SynthesizedAnswer(text: text, citations: [])
        }

        throw ClientError.decoding("Could not locate output text in response.")
    }

    private func extractText(from part: [String: Any]) -> String? {
        if let value = part["value"] as? String { return value }
        if let nested = part["text"] as? [String: Any] {
            return nested["value"] as? String
        }
        return nil
    }

    private func parseAnnotations(_ annotations: [[String: Any]]?) -> [FileCitation] {
        guard let annotations else { return [] }
        var seen = Set<String>()
        var result: [FileCitation] = []
        for annotation in annotations {
            let type = annotation["type"] as? String ?? ""
            guard type.contains("file_citation") || type.contains("file_path") else { continue }
            let fileId = (annotation["file_id"] as? String)
                ?? ((annotation["file_citation"] as? [String: Any])?["file_id"] as? String)
                ?? ""
            guard !fileId.isEmpty, !seen.contains(fileId) else { continue }
            seen.insert(fileId)
            let filename = (annotation["filename"] as? String)
                ?? ((annotation["file_citation"] as? [String: Any])?["filename"] as? String)
                ?? fileId
            let quote = (annotation["quote"] as? String)
                ?? ((annotation["file_citation"] as? [String: Any])?["quote"] as? String)
            result.append(FileCitation(fileId: fileId, filename: filename, quote: quote))
        }
        return result
    }

    /// Recursive search for any non-empty `"text"` string, used as a final
    /// fallback when the response shape doesn't match expectations.
    private func findFirstText(in value: Any) -> String? {
        if let string = value as? String, !string.isEmpty {
            return nil  // raw strings at unknown keys aren't safe to surface
        }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String, !text.isEmpty { return text }
            for (_, v) in dict {
                if let found = findFirstText(in: v) { return found }
            }
        }
        if let array = value as? [Any] {
            for v in array {
                if let found = findFirstText(in: v) { return found }
            }
        }
        return nil
    }
}
