import AppKit
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    let settings = ChatSettings()
    let fileIndex = FileIndexManager()

    @Published var query = ""
    @Published var response = ""
    @Published var webCitations: [ChatCitation] = []
    @Published var fileCitations: [ChatCitation] = []
    @Published var ragAnswer: String = ""
    @Published var ragCitations: [ChatCitation] = []
    @Published var ragState: RAGState = .idle
    @Published var status = "Type a question"
    @Published var isStreaming = false
    @Published var isShowingSettings = false
    @Published var focusToken = UUID()
    @Published var availableUpdate: AvailableUpdate?
    @Published var isCheckingForUpdate = false
    @Published var isUpdating = false
    @Published var isSharing = false

    /// Convenience for consumers (share/copy) that want the whole reference set.
    var citations: [ChatCitation] { webCitations + fileCitations + ragCitations }

    private var streamTask: Task<Void, Never>?
    private var fileSearchTask: Task<Void, Never>?
    private var ragTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var streamGeneration = 0
    private let updateManager = UpdateManager()

    /// Top file-search score required before we burn an LLM call on synthesis.
    /// Tuned conservatively; revisit once we have feel for typical scores.
    private static let ragScoreThreshold: Double = 0.3

    enum RAGState: Equatable {
        case idle
        case synthesizing
        case ready
        case failed
    }

    init() {
        Task { [weak self] in
            await self?.applyFileSearchSettings()
        }
    }

    /// Push current settings into the file index manager. Call after the
    /// settings sheet closes or when credentials change. Starts (or restarts)
    /// the FSEvents watcher and runs an initial sync when needed.
    func applyFileSearchSettings() async {
        let snapshot = settings.fileSearchSnapshot()
        let apiKey = snapshot.isEnabled ? snapshot.apiKey : ""
        await fileIndex.configure(apiKey: apiKey, folder: snapshot.folderURL)
        if snapshot.isEnabled {
            fileIndex.startWatching(folder: snapshot.folderURL)
        } else {
            fileIndex.stopWatching()
        }
    }

    func indexNow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyFileSearchSettings()
            let snapshot = self.settings.fileSearchSnapshot()
            guard snapshot.isEnabled else { return }
            self.fileIndex.sync(folder: snapshot.folderURL)
        }
    }

    func prepareForPresentation() {
        focusToken = UUID()
        checkForUpdatesIfNeeded()
    }

    func installUpdate() {
        guard let availableUpdate, !isUpdating else { return }

        isUpdating = true
        status = "Updating"

        Task { [weak self] in
            do {
                try await self?.updateManager.install(availableUpdate)
            } catch {
                await MainActor.run {
                    self?.response = error.localizedDescription
                    self?.status = "Update failed"
                    self?.isUpdating = false
                }
            }
        }
    }

    func settingsDidClose() {
        if settings.hasAPIKey, status == "Setup required" {
            response = ""
            status = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type a question" : "Ready"
        }
        Task { [weak self] in
            await self?.applyFileSearchSettings()
        }
    }

    func copyResponse() {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        status = "Copied"
    }

    func shareResponse() {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSharing else { return }

        isSharing = true
        status = "Sharing"

        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Share only the web answer + web citations. Local file content and
        // RAG synthesis stay on-device — they may contain personal data.
        let webRefs = webCitations
        Task { [weak self] in
            do {
                let url = try await LitterboxShareClient.share(
                    title: title.isEmpty ? "SolarLight Answer" : title,
                    markdown: trimmed,
                    webCitations: webRefs,
                    fileCitations: []
                )
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url.absoluteString, forType: .string)
                    self?.status = "Share link copied"
                    self?.isSharing = false
                }
            } catch {
                await MainActor.run {
                    self?.status = "Share failed"
                    self?.isSharing = false
                }
            }
        }
    }

    func queryChanged() {
        debounceTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            streamTask?.cancel()
            fileSearchTask?.cancel()
            ragTask?.cancel()
            response = ""
            webCitations = []
            fileCitations = []
            ragAnswer = ""
            ragCitations = []
            ragState = .idle
            status = "Type a question"
            isStreaming = false
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.submit()
        }
    }

    func submit() {
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        debounceTask?.cancel()
        streamTask?.cancel()
        fileSearchTask?.cancel()
        ragTask?.cancel()
        response = ""
        webCitations = []
        fileCitations = []
        ragAnswer = ""
        ragCitations = []
        ragState = .idle
        status = "Thinking"
        isStreaming = true

        streamGeneration += 1
        let generation = streamGeneration
        let configuration = settings.snapshot()

        startFileSearch(prompt: prompt, generation: generation)

        streamTask = Task { [weak self] in
            do {
                let client = ChatClient(configuration: configuration)
                let stream = try await client.streamChat(prompt: prompt)

                var pending = ""
                var lastFlush = ContinuousClock.now

                for try await event in stream {
                    if Task.isCancelled { return }

                    switch event {
                    case .citations(let newCitations):
                        await MainActor.run {
                            guard let self, self.streamGeneration == generation else { return }
                            self.mergeWebCitations(newCitations)
                            self.status = "Found references"
                        }
                    case .content(let token):
                        pending += token
                        let now = ContinuousClock.now
                        if now - lastFlush > .milliseconds(50) {
                            let toFlush = pending
                            pending = ""
                            lastFlush = now
                            await MainActor.run {
                                guard let self, self.streamGeneration == generation else { return }
                                self.response += toFlush
                                self.status = "Streaming"
                            }
                        }
                    }
                }

                let finalPending = pending
                await MainActor.run {
                    guard let self, self.streamGeneration == generation else { return }
                    if !finalPending.isEmpty { self.response += finalPending }
                    self.status = "Done"
                    self.isStreaming = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.streamGeneration == generation else { return }
                    self.response = error.localizedDescription
                    self.status = "Error"
                    self.isStreaming = false
                }
            }
        }
    }

    private func mergeWebCitations(_ newCitations: [ChatCitation]) {
        var seenIds = Set(webCitations.map(\.id))
        for citation in newCitations where !seenIds.contains(citation.id) {
            webCitations.append(citation)
            seenIds.insert(citation.id)
        }
    }

    /// Run file search in parallel with the chat stream. Results are written
    /// directly into `fileCitations` and rendered below the answer pane. When
    /// the top match is sufficiently relevant we also kick off RAG synthesis.
    /// Failures are swallowed; web search remains the source of truth.
    private func startFileSearch(prompt: String, generation: Int) {
        guard fileIndex.isReady else { return }

        fileSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await self.fileIndex.search(query: prompt, maxResults: 5)
                if Task.isCancelled { return }
                let citations = matches.compactMap { $0.toCitation() }
                let topScore = matches.map(\.score).max() ?? 0
                await MainActor.run {
                    guard self.streamGeneration == generation else { return }
                    self.fileCitations = citations
                    if topScore >= Self.ragScoreThreshold {
                        self.startRAGSynthesis(prompt: prompt, generation: generation)
                    }
                }
            } catch {
                // Silent failure — web answer continues unaffected.
            }
        }
    }

    /// Synthesize an answer grounded in the user's vector store via the
    /// Upstage Responses API. Runs only when the file search returned at
    /// least one match above the score threshold.
    private func startRAGSynthesis(prompt: String, generation: Int) {
        let apiKey = settings.upstageAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, let vectorStoreId = fileIndex.vectorStoreId else { return }

        ragState = .synthesizing
        ragAnswer = ""
        ragCitations = []

        let fileIndex = self.fileIndex
        ragTask = Task { [weak self] in
            do {
                let client = RAGClient(apiKey: apiKey)
                let answer = try await client.synthesize(query: prompt, vectorStoreId: vectorStoreId)
                if Task.isCancelled { return }

                // Resolve file_id citations to local URLs so they're clickable.
                var resolved: [ChatCitation] = []
                for citation in answer.citations {
                    if let url = fileIndex.localURL(forFileId: citation.fileId) {
                        resolved.append(ChatCitation(
                            title: citation.filename,
                            url: url,
                            kind: .file(snippet: citation.quote ?? "")
                        ))
                    }
                }

                await MainActor.run {
                    guard let self, self.streamGeneration == generation else { return }
                    self.ragAnswer = answer.text
                    self.ragCitations = resolved
                    self.ragState = .ready
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.streamGeneration == generation else { return }
                    self.ragState = .failed
                }
            }
        }
    }

    private func checkForUpdatesIfNeeded() {
        guard availableUpdate == nil, updateCheckTask == nil, !isCheckingForUpdate else { return }

        isCheckingForUpdate = true
        updateCheckTask = Task { [weak self] in
            do {
                let update = try await self?.updateManager.checkForAvailableUpdate()
                await MainActor.run {
                    self?.availableUpdate = update
                    self?.isCheckingForUpdate = false
                    self?.updateCheckTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.isCheckingForUpdate = false
                    self?.updateCheckTask = nil
                }
            }
        }
    }
}

private enum LitterboxShareClient {
    private static let uploadURL = URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!

    static func share(
        title: String,
        markdown: String,
        webCitations: [ChatCitation],
        fileCitations: [ChatCitation]
    ) async throws -> URL {
        let boundary = "SolarLightBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            fields: [
                "reqtype": "fileupload",
                "time": "1h"
            ],
            fileName: "answer.html",
            fileData: html(
                title: title,
                markdown: markdown,
                webCitations: webCitations,
                fileCitations: fileCitations
            ).data(using: .utf8) ?? Data()
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true else {
            throw URLError(.badServerResponse)
        }
        return url
    }

    private static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileName: String,
        fileData: Data
    ) -> Data {
        var data = Data()

        func append(_ string: String) {
            data.append(Data(string.utf8))
        }

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: text/html; charset=utf-8\r\n\r\n")
        data.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        return data
    }

    private static func html(
        title: String,
        markdown: String,
        webCitations: [ChatCitation],
        fileCitations: [ChatCitation]
    ) -> String {
        let renderInline: (String) -> String = { text in
            inlineHTML(text, webCitations: webCitations, fileCitations: fileCitations)
        }

        let body = markdown.components(separatedBy: .newlines).map { rawLine -> String in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return "" }

            if line.hasPrefix("### ") { return "<h3>\(renderInline(String(line.dropFirst(4))))</h3>" }
            if line.hasPrefix("## ") { return "<h2>\(renderInline(String(line.dropFirst(3))))</h2>" }
            if line.hasPrefix("# ") { return "<h1>\(renderInline(String(line.dropFirst(2))))</h1>" }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return "<p>&bull; \(renderInline(String(line.dropFirst(2))))</p>"
            }
            return "<p>\(renderInline(line))</p>"
        }.joined(separator: "\n")

        let webRefs = webCitations.enumerated().map { index, citation in
            """
            <li><a href="\(escape(citation.url.absoluteString))">\(index + 1). \(escape(citation.title))</a><br><span>\(escape(citation.url.host() ?? citation.url.absoluteString))</span></li>
            """
        }.joined(separator: "\n")

        let fileRefs = fileCitations.enumerated().map { index, citation in
            """
            <li><a href="\(escape(citation.url.absoluteString))">L\(index + 1). \(escape(citation.title))</a><br><span>Local file</span></li>
            """
        }.joined(separator: "\n")

        let referencesBlock: String = {
            var parts: [String] = []
            if !webRefs.isEmpty {
                parts.append("<ol>\(webRefs)</ol>")
            }
            if !fileRefs.isEmpty {
                parts.append("<h3>Local files</h3><ol>\(fileRefs)</ol>")
            }
            return parts.joined(separator: "\n")
        }()

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escape(title))</title>
          <style>
            body { font: 17px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.65; max-width: 860px; margin: 40px auto; padding: 0 22px; color: #202124; }
            h1, h2, h3 { line-height: 1.25; margin-top: 1.6em; }
            a { color: #0b7cff; text-decoration: none; }
            a:hover { text-decoration: underline; }
            .refs { margin-top: 42px; padding-top: 18px; border-top: 1px solid #ddd; }
            .refs span { color: #6b7280; font-size: 0.9em; }
            .hero { margin-bottom: 34px; }
            .eyebrow { color: #6b7280; font-size: 0.9em; font-weight: 700; letter-spacing: 0.02em; text-transform: uppercase; }
            .query { font-size: 1.45em; font-weight: 650; margin: 6px 0 0; }
            .section-title { align-items: center; display: flex; gap: 10px; margin-top: 24px; }
            .section-title h2 { margin: 0; }
            .icon { color: #0b7cff; font-size: 1.25em; }
            footer { margin-top: 44px; padding-top: 18px; border-top: 1px solid #ddd; color: #6b7280; font-size: 0.9em; }
          </style>
        </head>
        <body>
          <main>
            <section class="hero">
              <div class="eyebrow">⌕ Search Query</div>
              <p class="query">\(escape(title))</p>
            </section>
            <div class="section-title">
              <span class="icon">✦</span>
              <h2>Answer</h2>
            </div>
            \(body)
            <section class="refs">
              <h2>References</h2>
              \(referencesBlock)
            </section>
            <footer>
              Powered by <a href="https://github.com/hunkim/SolarLight">SolarLight</a>
            </footer>
          </main>
        </body>
        </html>
        """
    }

    private static func inlineHTML(
        _ text: String,
        webCitations: [ChatCitation],
        fileCitations: [ChatCitation]
    ) -> String {
        var result = ""
        var index = text.startIndex
        var isStrong = false

        while index < text.endIndex {
            if text[index...].hasPrefix("**") {
                result += isStrong ? "</strong>" : "<strong>"
                isStrong.toggle()
                index = text.index(index, offsetBy: 2)
                continue
            }

            if text[index] == "[", let close = text[index...].firstIndex(of: "]") {
                let value = String(text[text.index(after: index)..<close])
                if let n = Int(value), webCitations.indices.contains(n - 1) {
                    let citation = webCitations[n - 1]
                    result += "<a href=\"\(escape(citation.url.absoluteString))\">[\(n)]</a>"
                    index = text.index(after: close)
                    continue
                }
                if (value.first == "L" || value.first == "l"),
                   let n = Int(value.dropFirst()),
                   fileCitations.indices.contains(n - 1) {
                    let citation = fileCitations[n - 1]
                    result += "<a href=\"\(escape(citation.url.absoluteString))\">[L\(n)]</a>"
                    index = text.index(after: close)
                    continue
                }
            }

            result += escape(String(text[index]))
            index = text.index(after: index)
        }

        if isStrong {
            result += "</strong>"
        }

        return result
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
