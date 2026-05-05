import Foundation

/// Low-level client for Upstage Files API + Vector Stores API + File Search.
///
/// Endpoints (https://api.upstage.ai/v2):
///   - POST /files                                       Upload a file (multipart).
///   - DELETE /files/{id}                                Delete a file.
///   - POST /vector_stores                               Create a vector store.
///   - GET  /vector_stores/{vsid}                        Retrieve a vector store.
///   - POST /vector_stores/{vsid}/files                  Add an indexed file by file_id.
///   - GET  /vector_stores/{vsid}/files/{file_id}        Poll file indexing status.
///   - DELETE /vector_stores/{vsid}/files/{file_id}      Remove a file from the store.
///   - POST /vector_stores/{vsid}/search                 Vector search.
struct UpstageFileSearchClient {
    static let defaultBaseURL = "https://api.upstage.ai/v2"

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case badResponse(Int, String?)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Upstage API key is not configured."
            case .invalidURL:
                return "Upstage base URL is not valid."
            case .badResponse(let status, let detail):
                if let detail, !detail.isEmpty {
                    return "Upstage API returned HTTP \(status): \(detail)"
                }
                return "Upstage API returned HTTP \(status)."
            case .decoding(let message):
                return "Failed to decode Upstage response: \(message)"
            }
        }
    }

    let apiKey: String
    let baseURL: String
    let session: URLSession

    init(apiKey: String, baseURL: String = UpstageFileSearchClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - DTOs

    struct UploadedFile: Decodable {
        let id: String
        let filename: String?
        let bytes: Int?
        let createdAt: Int?

        enum CodingKeys: String, CodingKey {
            case id, filename, bytes
            case createdAt = "created_at"
        }
    }

    struct VectorStore: Decodable {
        let id: String
        let name: String?
        let status: String?
    }

    struct VectorStoreFile: Decodable {
        let id: String
        let status: String
        let lastError: ErrorPayload?

        enum CodingKeys: String, CodingKey {
            case id, status
            case lastError = "last_error"
        }

        struct ErrorPayload: Decodable {
            let code: String?
            let message: String?
        }
    }

    struct SearchResponse: Decodable {
        let data: [SearchResult]
    }

    struct SearchResult: Decodable {
        let fileId: String?
        let filename: String?
        let score: Double?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case fileId = "file_id"
            case filename, score, text
        }
    }

    // MARK: - Public API

    func createVectorStore(name: String) async throws -> VectorStore {
        let request = try makeJSONRequest(path: "vector_stores", method: "POST", body: ["name": name])
        return try await send(request, decoding: VectorStore.self)
    }

    func getVectorStore(id: String) async throws -> VectorStore {
        let request = try makeJSONRequest(path: "vector_stores/\(id)", method: "GET")
        return try await send(request, decoding: VectorStore.self)
    }

    /// Uploads a local file via multipart form-data with `purpose=user_data`.
    func uploadFile(at url: URL) async throws -> UploadedFile {
        let endpoint = try buildURL(path: "files")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "SolarLight-FS-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: url)
        let filename = url.lastPathComponent
        let mimeType = mimeType(for: url)

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
        append("user_data\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        return try await send(request, decoding: UploadedFile.self)
    }

    func deleteFile(id: String) async throws {
        let request = try makeJSONRequest(path: "files/\(id)", method: "DELETE")
        try await sendIgnoringBody(request)
    }

    /// Add an uploaded file to a vector store. The returned `status` will
    /// initially be "in_progress"; poll `getVectorStoreFile` until "completed"
    /// or "failed".
    func addFileToVectorStore(vectorStoreId: String, fileId: String) async throws -> VectorStoreFile {
        let request = try makeJSONRequest(
            path: "vector_stores/\(vectorStoreId)/files",
            method: "POST",
            body: ["file_id": fileId]
        )
        return try await send(request, decoding: VectorStoreFile.self)
    }

    func getVectorStoreFile(vectorStoreId: String, fileId: String) async throws -> VectorStoreFile {
        let request = try makeJSONRequest(
            path: "vector_stores/\(vectorStoreId)/files/\(fileId)",
            method: "GET"
        )
        return try await send(request, decoding: VectorStoreFile.self)
    }

    func removeFileFromVectorStore(vectorStoreId: String, fileId: String) async throws {
        let request = try makeJSONRequest(
            path: "vector_stores/\(vectorStoreId)/files/\(fileId)",
            method: "DELETE"
        )
        try await sendIgnoringBody(request)
    }

    func search(vectorStoreId: String, query: String, maxResults: Int = 5) async throws -> [SearchResult] {
        let clamped = min(max(maxResults, 1), 20)
        let request = try makeJSONRequest(
            path: "vector_stores/\(vectorStoreId)/search",
            method: "POST",
            body: ["query": query, "max_num_results": clamped] as [String: Any]
        )
        let response = try await send(request, decoding: SearchResponse.self)
        return response.data
    }

    // MARK: - Internals

    private func buildURL(path: String) throws -> URL {
        guard let base = URL(string: baseURL) else {
            throw ClientError.invalidURL
        }
        return base.appending(path: path)
    }

    private func makeJSONRequest(path: String, method: String, body: Any? = nil) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }
        var request = URLRequest(url: try buildURL(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(error.localizedDescription)
        }
    }

    private func sendIgnoringBody(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let detail = String(data: data, encoding: .utf8)?.prefix(500).description
        throw ClientError.badResponse(http.statusCode, detail)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "hwp", "hwpx": return "application/x-hwp"
        case "md": return "text/markdown"
        case "txt": return "text/plain"
        case "jpeg", "jpg": return "image/jpeg"
        case "png": return "image/png"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}

extension UpstageFileSearchClient {
    /// Extensions accepted by Upstage File Search.
    static let supportedExtensions: Set<String> = [
        "pdf", "docx", "pptx", "xlsx", "hwp", "hwpx",
        "md", "txt",
        "jpeg", "jpg", "png", "bmp", "tiff", "tif", "heic"
    ]
}
