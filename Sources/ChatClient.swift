import Foundation

struct ChatCitation: Identifiable, Equatable {
    var id: String { url.absoluteString }

    let title: String
    let url: URL
}

enum ChatStreamEvent {
    case citations([ChatCitation])
    case content(String)
}

struct ChatClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case badResponse(Int, String?)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The base URL is not valid."
            case .badResponse(let statusCode, let detail):
                if let detail, !detail.isEmpty {
                    return "The API returned HTTP \(statusCode): \(detail)"
                }
                return "The API returned HTTP \(statusCode)."
            }
        }
    }

    private let apiKey: String
    private let baseURL: String
    private let model: String

    init(configuration: ChatConfiguration) {
        self.apiKey = configuration.apiKey
        self.baseURL = configuration.baseURL
        self.model = configuration.model
    }

    func streamChat(prompt: String) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let request = try apiKey.isEmpty
            ? makeProxyRequest(prompt: prompt)
            : makeOpenAIRequest(prompt: prompt)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let detail = try? await responseSnippet(from: bytes)
            throw ClientError.badResponse(httpResponse.statusCode, detail)
        }

        return AsyncThrowingStream { continuation in
            let decoder = JSONDecoder()
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }

                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        let chunk = try decoder.decode(ChatStreamChunk.self, from: data)
                        let delta = chunk.choices.first?.delta

                        if let annotations = delta?.annotations {
                            let citations = annotations.compactMap(\.citation)
                            if !citations.isEmpty {
                                continuation.yield(.citations(citations))
                            }
                        }

                        if let content = delta?.content {
                            continuation.yield(.content(content))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeProxyRequest(prompt: String) throws -> URLRequest {
        guard let url = URL(string: SolarDefaults.proxyURL)?.appending(path: "api/search-simple") else {
            throw ClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ProxyRequest(query: prompt))
        return request
    }

    private func makeOpenAIRequest(prompt: String) throws -> URLRequest {
        guard let base = URL(string: baseURL) else {
            throw ClientError.invalidURL
        }
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You are a concise desktop assistant. Answer directly and avoid unnecessary preamble."),
                .init(role: "user", content: prompt)
            ],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func responseSnippet(from bytes: URLSession.AsyncBytes) async throws -> String? {
        var lines: [String] = []
        var length = 0

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            lines.append(trimmed)
            length += trimmed.count
            if length >= 500 {
                break
            }
        }

        let snippet = lines.joined(separator: " ")
        return snippet.isEmpty ? nil : String(snippet.prefix(500))
    }
}

enum AppConfiguration {
    static func load() -> [String: String] {
        var values = ProcessInfo.processInfo.environment

        for fileURL in configFileURLs() {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            parse(contents).forEach { key, value in
                values[key] = value
            }
        }

        return values
    }

    private static func configFileURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: ".solarlight.env"),
            home.appending(path: ".config/solarlight/env"),
            home.appending(path: ".spotlightchat.env"),
            home.appending(path: ".config/spotlightchat/env")
        ]
    }

    private static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }

            var key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            if key.hasPrefix("export ") {
                key.removeFirst("export ".count)
                key = key.trimmingCharacters(in: .whitespaces)
            }

            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }

            if value.count >= 2, value.first == "'", value.last == "'" {
                value.removeFirst()
                value.removeLast()
            }

            result[key] = value
        }

        return result
    }
}

private struct ProxyRequest: Encodable {
    let query: String
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
}

private struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let annotations: [Annotation]?
        }

        let delta: Delta
    }

    let choices: [Choice]
}

private struct Annotation: Decodable {
    struct URLCitation: Decodable {
        let title: String
        let url: URL
    }

    let type: String
    let urlCitation: URLCitation?

    var citation: ChatCitation? {
        guard type == "url_citation", let urlCitation else {
            return nil
        }

        return ChatCitation(
            title: urlCitation.title.decodingHTMLEntities(),
            url: urlCitation.url
        )
    }

    enum CodingKeys: String, CodingKey {
        case type
        case urlCitation = "url_citation"
    }
}

private extension String {
    func decodingHTMLEntities() -> String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
