import Foundation

struct ChatConfiguration {
    let apiKey: String
    let baseURL: String
    let model: String
}

@MainActor
final class ChatSettings: ObservableObject {
    @Published var apiKey: String
    @Published var baseURL: String
    @Published var model: String
    @Published var runAtStartup: Bool
    @Published var startupError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loaded = AppConfiguration.load()
        self.apiKey = defaults.string(forKey: Keys.apiKey) ?? loaded["OPENAI_API_KEY"] ?? loaded["UPSTAGE_API_KEY"] ?? ""
        self.baseURL = defaults.string(forKey: Keys.baseURL) ?? loaded["OPENAI_BASE_URL"] ?? ""
        self.model = defaults.string(forKey: Keys.model) ?? loaded["OPENAI_MODEL"] ?? ""
        self.runAtStartup = StartupManager.isEnabled
    }

    func save() {
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apiKey)
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
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

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum Keys {
    static let apiKey = "apiKey"
    static let baseURL = "baseURL"
    static let model = "model"
}
