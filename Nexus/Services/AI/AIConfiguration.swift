import Foundation
import Security

/// AI settings: opt-in, Keychain-backed keys, provider selection.
/// Vault opens and works fully with AI disabled (local-first guarantee).
@MainActor
final class AIConfiguration: ObservableObject {
    static let shared = AIConfiguration()

    enum ProviderKind: String, CaseIterable, Identifiable {
        case disabled
        case xai
        case ollama
        case openAICompatible

        var id: String { rawValue }

        var title: String {
            switch self {
            case .disabled: return "Disabled (offline)"
            case .xai: return "SpaceXAI (xAI)"
            case .ollama: return "Ollama (local)"
            case .openAICompatible: return "OpenAI-compatible"
            }
        }
    }

    enum ScopeMode: String, CaseIterable, Identifiable {
        case entireVault
        case currentNote
        case currentAndBacklinks
        case selectedFolder
        case selectedTags

        var id: String { rawValue }

        var title: String {
            switch self {
            case .entireVault: return "Entire vault"
            case .currentNote: return "Current note"
            case .currentAndBacklinks: return "Note + backlinks"
            case .selectedFolder: return "Current folder"
            case .selectedTags: return "Notes sharing tags"
            }
        }
    }

    @Published var providerKind: ProviderKind {
        didSet { UserDefaults.standard.set(providerKind.rawValue, forKey: Keys.provider) }
    }

    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Keys.model) }
    }

    @Published var ollamaBaseURL: String {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: Keys.ollamaURL) }
    }

    @Published var openAIBaseURL: String {
        didSet { UserDefaults.standard.set(openAIBaseURL, forKey: Keys.openAIURL) }
    }

    @Published var scopeMode: ScopeMode {
        didSet { UserDefaults.standard.set(scopeMode.rawValue, forKey: Keys.scope) }
    }

    @Published var allowGeneralKnowledge: Bool {
        didSet { UserDefaults.standard.set(allowGeneralKnowledge, forKey: Keys.general) }
    }

    /// In-memory only mirror; never write API keys to vault files.
    @Published private(set) var hasXAIKey: Bool = false
    @Published private(set) var hasOpenAIKey: Bool = false

    var isEnabled: Bool {
        switch providerKind {
        case .disabled: return false
        case .xai: return hasXAIKey
        case .ollama: return true
        case .openAICompatible: return hasOpenAIKey
        }
    }

    private enum Keys {
        static let provider = "nexus.ai.provider"
        static let model = "nexus.ai.model"
        static let ollamaURL = "nexus.ai.ollamaURL"
        static let openAIURL = "nexus.ai.openAIURL"
        static let scope = "nexus.ai.scope"
        static let general = "nexus.ai.allowGeneral"
        static let xaiKeychain = "nexus.ai.xai.apiKey"
        static let openAIKeychain = "nexus.ai.openai.apiKey"
    }

    private init() {
        let p = UserDefaults.standard.string(forKey: Keys.provider) ?? ProviderKind.disabled.rawValue
        providerKind = ProviderKind(rawValue: p) ?? .disabled
        modelID = UserDefaults.standard.string(forKey: Keys.model) ?? "grok-4.5"
        ollamaBaseURL = UserDefaults.standard.string(forKey: Keys.ollamaURL) ?? "http://127.0.0.1:11434"
        openAIBaseURL = UserDefaults.standard.string(forKey: Keys.openAIURL) ?? "https://api.openai.com/v1"
        let s = UserDefaults.standard.string(forKey: Keys.scope) ?? ScopeMode.entireVault.rawValue
        scopeMode = ScopeMode(rawValue: s) ?? .entireVault
        allowGeneralKnowledge = UserDefaults.standard.bool(forKey: Keys.general)
        refreshKeyFlags()
    }

    func refreshKeyFlags() {
        hasXAIKey = KeychainHelper.load(account: Keys.xaiKeychain) != nil
            || ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil
        hasOpenAIKey = KeychainHelper.load(account: Keys.openAIKeychain) != nil
            || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
    }

    func setXAIKey(_ key: String?) {
        if let key, !key.isEmpty {
            KeychainHelper.save(account: Keys.xaiKeychain, value: key)
        } else {
            KeychainHelper.delete(account: Keys.xaiKeychain)
        }
        refreshKeyFlags()
    }

    func setOpenAIKey(_ key: String?) {
        if let key, !key.isEmpty {
            KeychainHelper.save(account: Keys.openAIKeychain, value: key)
        } else {
            KeychainHelper.delete(account: Keys.openAIKeychain)
        }
        refreshKeyFlags()
    }

    func xaiAPIKey() -> String? {
        KeychainHelper.load(account: Keys.xaiKeychain)
            ?? ProcessInfo.processInfo.environment["XAI_API_KEY"]
    }

    func openAIAPIKey() -> String? {
        KeychainHelper.load(account: Keys.openAIKeychain)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    func makeProvider() -> (any AIProvider)? {
        switch providerKind {
        case .disabled:
            return nil
        case .xai:
            guard let key = xaiAPIKey() else { return nil }
            return OpenAICompatibleProvider(
                name: "SpaceXAI",
                baseURL: URL(string: "https://api.x.ai/v1")!,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "grok-4.5" : modelID
            )
        case .ollama:
            let base = URL(string: ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
            return OllamaProvider(
                baseURL: base,
                defaultModel: modelID.isEmpty ? "llama3.2" : modelID
            )
        case .openAICompatible:
            guard let key = openAIAPIKey() else { return nil }
            let base = URL(string: openAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            return OpenAICompatibleProvider(
                name: "OpenAI-compatible",
                baseURL: base,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "gpt-4o-mini" : modelID
            )
        }
    }
}

// MARK: - Keychain

enum KeychainHelper {
    static func save(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghost64.nexus",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghost64.nexus",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghost64.nexus",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
