import AppKit
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    let settings = ChatSettings()

    @Published var query = ""
    @Published var response = ""
    @Published var citations: [ChatCitation] = []
    @Published var status = "Type a question"
    @Published var isStreaming = false
    @Published var isShowingSettings = false
    @Published var focusToken = UUID()
    @Published var availableUpdate: AvailableUpdate?
    @Published var isCheckingForUpdate = false
    @Published var isUpdating = false
    @Published var isSharing = false

    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var streamGeneration = 0
    private let updateManager = UpdateManager()

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
        let currentCitations = citations
        Task { [weak self] in
            do {
                let url = try await LitterboxShareClient.share(
                    title: title.isEmpty ? "SolarLight Answer" : title,
                    markdown: trimmed,
                    citations: currentCitations
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
            response = ""
            citations = []
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
        response = ""
        citations = []
        status = "Thinking"
        isStreaming = true

        streamGeneration += 1
        let generation = streamGeneration
        let configuration = settings.snapshot()

        streamTask = Task { [weak self] in
            do {
                let client = ChatClient(configuration: configuration)
                let stream = try await client.streamChat(prompt: prompt)

                var pending = ""
                var lastFlush = ContinuousClock.now

                for try await event in stream {
                    if Task.isCancelled { return }

                    switch event {
                    case .citations(let citations):
                        await MainActor.run {
                            guard let self, self.streamGeneration == generation else { return }
                            self.mergeCitations(citations)
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

    private func mergeCitations(_ newCitations: [ChatCitation]) {
        var seen = Set(citations.map(\.url))
        for citation in newCitations where !seen.contains(citation.url) {
            citations.append(citation)
            seen.insert(citation.url)
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

    static func share(title: String, markdown: String, citations: [ChatCitation]) async throws -> URL {
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
            fileData: html(title: title, markdown: markdown, citations: citations).data(using: .utf8) ?? Data()
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

    private static func html(title: String, markdown: String, citations: [ChatCitation]) -> String {
        let body = markdown.components(separatedBy: .newlines).map { rawLine -> String in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return "" }

            if line.hasPrefix("### ") { return "<h3>\(inlineHTML(String(line.dropFirst(4)), citations: citations))</h3>" }
            if line.hasPrefix("## ") { return "<h2>\(inlineHTML(String(line.dropFirst(3)), citations: citations))</h2>" }
            if line.hasPrefix("# ") { return "<h1>\(inlineHTML(String(line.dropFirst(2)), citations: citations))</h1>" }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return "<p>&bull; \(inlineHTML(String(line.dropFirst(2)), citations: citations))</p>"
            }
            return "<p>\(inlineHTML(line, citations: citations))</p>"
        }.joined(separator: "\n")

        let references = citations.enumerated().map { index, citation in
            """
            <li><a href="\(escape(citation.url.absoluteString))">\(index + 1). \(escape(citation.title))</a><br><span>\(escape(citation.url.host() ?? citation.url.absoluteString))</span></li>
            """
        }.joined(separator: "\n")

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
              <ol>
                \(references)
              </ol>
            </section>
            <footer>
              Powered by <a href="https://github.com/hunkim/SolarLight">SolarLight</a>
            </footer>
          </main>
        </body>
        </html>
        """
    }

    private static func inlineHTML(_ text: String, citations: [ChatCitation]) -> String {
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
                if let number = Int(value), citations.indices.contains(number - 1) {
                    let citation = citations[number - 1]
                    result += "<a href=\"\(escape(citation.url.absoluteString))\">[\(number)]</a>"
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
