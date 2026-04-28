import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    let settings = ChatSettings()

    @Published var query = ""
    @Published var response = ""
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
    private let updateManager = UpdateManager()

    func prepareForPresentation() {
        focusToken = UUID()
        checkForUpdatesIfNeeded()

        if !settings.hasAPIKey {
            response = "Add your Upstage API key to start chatting."
            status = "Setup required"
            isShowingSettings = true
        }
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

        prepareForPresentation()
    }

    func queryChanged() {
        debounceTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            streamTask?.cancel()
            response = ""
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
        guard settings.hasAPIKey else {
            debounceTask?.cancel()
            streamTask?.cancel()
            response = "Add your Upstage API key to start chatting."
            status = "Setup required"
            isStreaming = false
            isShowingSettings = true
            return
        }

        debounceTask?.cancel()
        streamTask?.cancel()
        response = ""
        status = "Thinking"
        isStreaming = true

        streamTask = Task { [weak self] in
            do {
                let configuration = await MainActor.run {
                    self?.settings.snapshot()
                }
                guard let configuration else { return }

                let client = try ChatClient(configuration: configuration)
                let stream = try await client.streamChat(prompt: prompt)

                for try await token in stream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.response += token
                        self?.status = "Streaming"
                    }
                }

                await MainActor.run {
                    self?.status = "Done"
                    self?.isStreaming = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.response = error.localizedDescription
                    self?.status = "Error"
                    self?.isStreaming = false
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
