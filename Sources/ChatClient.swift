import Foundation

struct ChatClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an API key in settings to start chatting."
            case .invalidURL:
                return "The base URL is not valid."
            case .badResponse(let statusCode):
                return "The API returned HTTP \(statusCode)."
            }
        }
    }

    private let apiKey: String
    private let baseURL: URL
    private let model: String

    init(environment: [String: String] = AppConfiguration.load()) throws {
        let apiKey = environment["OPENAI_API_KEY"] ?? environment["UPSTAGE_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        let baseURLString = environment["OPENAI_BASE_URL"] ?? "https://api.upstage.ai/v1"
        guard let baseURL = URL(string: baseURLString) else {
            throw ClientError.invalidURL
        }

        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = environment["OPENAI_MODEL"] ?? "solar-pro3"
    }

    init(configuration: ChatConfiguration) throws {
        guard !configuration.apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }
        guard let baseURL = URL(string: configuration.baseURL) else {
            throw ClientError.invalidURL
        }

        self.apiKey = configuration.apiKey
        self.baseURL = baseURL
        self.model = configuration.model.isEmpty ? "solar-pro3" : configuration.model
    }

    func streamChat(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let url = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: url)
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

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw ClientError.badResponse(httpResponse.statusCode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }

                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
                        if let content = chunk.choices.first?.delta.content {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }

            result[key] = value
        }

        return result
    }
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
        }

        let delta: Delta
    }

    let choices: [Choice]
}
