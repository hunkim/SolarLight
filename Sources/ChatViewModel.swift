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
                let client = try ChatClient(configuration: configuration)
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
