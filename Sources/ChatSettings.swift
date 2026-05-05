import Foundation

struct ChatConfiguration {
    let apiKey: String
    let baseURL: String
    let model: String
}

struct FileSearchConfiguration {
    let isEnabled: Bool
    let apiKey: String
    let folderURL: URL
}

@MainActor
final class ChatSettings: ObservableObject {
    @Published var apiKey: String
    @Published var baseURL: String
    @Published var model: String
    @Published var runAtStartup: Bool
    @Published var startupError: String?

    @Published var upstageAPIKey: String
    @Published var isFileSearchEnabled: Bool
    @Published var fileSearchFolderPath: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loaded = AppConfiguration.load()
        self.apiKey = defaults.string(forKey: Keys.apiKey) ?? loaded["OPENAI_API_KEY"] ?? loaded["UPSTAGE_API_KEY"] ?? ""
        self.baseURL = defaults.string(forKey: Keys.baseURL) ?? loaded["OPENAI_BASE_URL"] ?? ""
        self.model = defaults.string(forKey: Keys.model) ?? loaded["OPENAI_MODEL"] ?? ""
        self.runAtStartup = StartupManager.isEnabled

        self.upstageAPIKey = defaults.string(forKey: Keys.upstageAPIKey)
            ?? loaded["UPSTAGE_FILE_SEARCH_API_KEY"]
            ?? loaded["UPSTAGE_API_KEY"]
            ?? ""
        self.isFileSearchEnabled = defaults.bool(forKey: Keys.fileSearchEnabled)
        self.fileSearchFolderPath = defaults.string(forKey: Keys.fileSearchFolderPath)
            ?? FileIndexManager.defaultFolderURL().path
    }

    func save() {
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
        defaults.set(upstageAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.upstageAPIKey)
        defaults.set(isFileSearchEnabled, forKey: Keys.fileSearchEnabled)
        defaults.set(fileSearchFolderPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.fileSearchFolderPath)
    }

    func refreshStartupState() {
        runAtStartup = StartupManager.isEnabled
    }

    func setRunAtStartup(_ isEnabled: Bool) {
        do {
            try StartupManager.setEnabled(isEnabled)
            runAtStartup = StartupManager.isEnabled
            startupError = nil
        } catch {
            runAtStartup = StartupManager.isEnabled
            startupError = error.localizedDescription
        }
    }

    func snapshot() -> ChatConfiguration {
        ChatConfiguration(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func fileSearchSnapshot() -> FileSearchConfiguration {
        let trimmedKey = upstageAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = fileSearchFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = path.isEmpty
            ? FileIndexManager.defaultFolderURL()
            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return FileSearchConfiguration(
            isEnabled: isFileSearchEnabled && !trimmedKey.isEmpty,
            apiKey: trimmedKey,
            folderURL: folder
        )
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasFileSearchKey: Bool {
        !upstageAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum Keys {
    static let apiKey = "apiKey"
    static let baseURL = "baseURL"
    static let model = "model"
    static let upstageAPIKey = "upstageFileSearchAPIKey"
    static let fileSearchEnabled = "fileSearchEnabled"
    static let fileSearchFolderPath = "fileSearchFolderPath"
}
