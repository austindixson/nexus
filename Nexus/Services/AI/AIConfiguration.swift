import Foundation
import Security

/// AI settings: opt-in, Keychain-backed keys, provider selection.
/// Vault opens and works fully with AI disabled (local-first guarantee).
@MainActor
final class AIConfiguration: ObservableObject {
    static let shared = AIConfiguration()

    enum ProviderKind: String, CaseIterable, Identifiable, Hashable {
        case disabled
        case openai
        case xai
        case anthropic
        case ollama
        case remoteOpenAI

        var id: String { rawValue }

        var title: String {
            switch self {
            case .disabled: return "Disabled (offline)"
            case .openai: return "OpenAI"
            case .xai: return "SpaceXAI (xAI)"
            case .anthropic: return "Anthropic (Claude)"
            case .ollama: return "Ollama"
            case .remoteOpenAI: return "Remote OpenAI-compatible"
            }
        }

        /// Cloud / remote gateways need a Keychain (or env) API key before Ask is live.
        var requiresAPIKey: Bool {
            switch self {
            case .disabled, .ollama: return false
            case .openai, .xai, .anthropic, .remoteOpenAI: return true
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

    enum ConnectionTestResult: Equatable {
        case ok(String)
        case failure(String)
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

    /// Custom base for Remote OpenAI-compatible (OpenRouter, LiteLLM, Tailscale Funnel, etc.).
    @Published var remoteOpenAIBaseURL: String {
        didSet { UserDefaults.standard.set(remoteOpenAIBaseURL, forKey: Keys.remoteOpenAIURL) }
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
    @Published private(set) var hasAnthropicKey: Bool = false
    @Published private(set) var hasRemoteOpenAIKey: Bool = false

    var isEnabled: Bool {
        switch providerKind {
        case .disabled: return false
        case .openai: return hasOpenAIKey
        case .xai: return hasXAIKey
        case .anthropic: return hasAnthropicKey
        case .ollama: return true
        case .remoteOpenAI: return hasRemoteOpenAIKey
        }
    }

    private enum Keys {
        static let provider = "nexus.ai.provider"
        static let model = "nexus.ai.model"
        static let ollamaURL = "nexus.ai.ollamaURL"
        static let openAIURL = "nexus.ai.openAIURL" // legacy; migrated into remoteOpenAIURL
        static let remoteOpenAIURL = "nexus.ai.remoteOpenAIURL"
        static let scope = "nexus.ai.scope"
        static let general = "nexus.ai.allowGeneral"
        static let xaiKeychain = "nexus.ai.xai.apiKey"
        static let openAIKeychain = "nexus.ai.openai.apiKey"
        static let anthropicKeychain = "nexus.ai.anthropic.apiKey"
        static let remoteOpenAIKeychain = "nexus.ai.remote.apiKey"
    }

    static let openAIAPIBase = "https://api.openai.com/v1"
    static let xaiAPIBase = "https://api.x.ai/v1"
    static let anthropicAPIBase = "https://api.anthropic.com"

    private init() {
        let storedURL = UserDefaults.standard.string(forKey: Keys.remoteOpenAIURL)
            ?? UserDefaults.standard.string(forKey: Keys.openAIURL)
            ?? Self.openAIAPIBase
        remoteOpenAIBaseURL = storedURL

        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? ProviderKind.disabled.rawValue
        let migrated = Self.migrateProvider(raw: raw, remoteURL: storedURL)
        providerKind = migrated
        if migrated.rawValue != raw {
            UserDefaults.standard.set(migrated.rawValue, forKey: Keys.provider)
        }

        modelID = UserDefaults.standard.string(forKey: Keys.model) ?? "grok-4.5"
        ollamaBaseURL = UserDefaults.standard.string(forKey: Keys.ollamaURL) ?? "http://127.0.0.1:11434"
        let s = UserDefaults.standard.string(forKey: Keys.scope) ?? ScopeMode.entireVault.rawValue
        scopeMode = ScopeMode(rawValue: s) ?? .entireVault
        allowGeneralKnowledge = UserDefaults.standard.bool(forKey: Keys.general)
        refreshKeyFlags()
    }

    /// Maps legacy `openAICompatible` to OpenAI vs Remote based on base URL host.
    nonisolated static func migrateProvider(raw: String, remoteURL: String) -> ProviderKind {
        if raw == "openAICompatible" {
            let host = URL(string: remoteURL)?.host?.lowercased() ?? ""
            if host.isEmpty || host == "api.openai.com" {
                return .openai
            }
            return .remoteOpenAI
        }
        return ProviderKind(rawValue: raw) ?? .disabled
    }

    func refreshKeyFlags() {
        hasXAIKey = KeychainHelper.load(account: Keys.xaiKeychain) != nil
            || ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil
        hasOpenAIKey = KeychainHelper.load(account: Keys.openAIKeychain) != nil
            || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        hasAnthropicKey = KeychainHelper.load(account: Keys.anthropicKeychain) != nil
            || ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil
        hasRemoteOpenAIKey = KeychainHelper.load(account: Keys.remoteOpenAIKeychain) != nil
            || KeychainHelper.load(account: Keys.openAIKeychain) != nil
            || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
    }

    func setXAIKey(_ key: String?) {
        saveKey(key, account: Keys.xaiKeychain)
    }

    func setOpenAIKey(_ key: String?) {
        saveKey(key, account: Keys.openAIKeychain)
    }

    func setAnthropicKey(_ key: String?) {
        saveKey(key, account: Keys.anthropicKeychain)
    }

    func setRemoteOpenAIKey(_ key: String?) {
        saveKey(key, account: Keys.remoteOpenAIKeychain)
    }

    private func saveKey(_ key: String?, account: String) {
        if let key, !key.isEmpty {
            KeychainHelper.save(account: account, value: key)
        } else {
            KeychainHelper.delete(account: account)
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

    func anthropicAPIKey() -> String? {
        KeychainHelper.load(account: Keys.anthropicKeychain)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    func remoteOpenAIAPIKey() -> String? {
        KeychainHelper.load(account: Keys.remoteOpenAIKeychain)
            ?? KeychainHelper.load(account: Keys.openAIKeychain)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    /// Normalize user-entered base URL (trim, strip trailing slash, require http(s)).
    nonisolated static func normalizeBaseURL(_ string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    func makeProvider() -> (any AIProvider)? {
        switch providerKind {
        case .disabled:
            return nil
        case .openai:
            guard let key = openAIAPIKey() else { return nil }
            guard let base = Self.normalizeBaseURL(Self.openAIAPIBase) else { return nil }
            return OpenAICompatibleProvider(
                name: "OpenAI",
                baseURL: base,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "gpt-4o-mini" : modelID
            )
        case .xai:
            guard let key = xaiAPIKey() else { return nil }
            guard let base = Self.normalizeBaseURL(Self.xaiAPIBase) else { return nil }
            return OpenAICompatibleProvider(
                name: "SpaceXAI",
                baseURL: base,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "grok-4.5" : modelID
            )
        case .anthropic:
            guard let key = anthropicAPIKey() else { return nil }
            guard let base = Self.normalizeBaseURL(Self.anthropicAPIBase) else { return nil }
            return AnthropicProvider(
                baseURL: base,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "claude-sonnet-4-5" : modelID
            )
        case .ollama:
            guard let base = Self.normalizeBaseURL(ollamaBaseURL)
                    ?? URL(string: "http://127.0.0.1:11434")
            else { return nil }
            return OllamaProvider(
                baseURL: base,
                defaultModel: modelID.isEmpty ? "llama3.2" : modelID
            )
        case .remoteOpenAI:
            guard let key = remoteOpenAIAPIKey() else { return nil }
            guard let base = Self.normalizeBaseURL(remoteOpenAIBaseURL) else { return nil }
            return OpenAICompatibleProvider(
                name: "Remote",
                baseURL: base,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "gpt-4o-mini" : modelID
            )
        }
    }

    /// Seeds a sensible default model when switching providers (only if empty / previous default).
    func applyDefaultModelIfNeeded(for kind: ProviderKind) {
        let defaults: [ProviderKind: String] = [
            .openai: "gpt-4o-mini",
            .xai: "grok-4.5",
            .anthropic: "claude-sonnet-4-5",
            .ollama: "llama3.2",
            .remoteOpenAI: "gpt-4o-mini",
        ]
        guard let next = defaults[kind] else { return }
        let previousDefaults = Set(defaults.values)
        if modelID.isEmpty || previousDefaults.contains(modelID) {
            modelID = next
        }
    }

    /// Cheap reachability / auth probe for the selected provider.
    func testConnection() async -> ConnectionTestResult {
        switch providerKind {
        case .disabled:
            return .failure("Select a provider first.")
        case .ollama:
            return await testOllama()
        case .openai:
            guard let key = openAIAPIKey() else { return .failure("Add an OpenAI API key.") }
            guard let base = Self.normalizeBaseURL(Self.openAIAPIBase) else {
                return .failure("Invalid OpenAI base URL.")
            }
            return await testOpenAICompatible(base: base, apiKey: key, label: "OpenAI")
        case .xai:
            guard let key = xaiAPIKey() else { return .failure("Add an xAI API key.") }
            guard let base = Self.normalizeBaseURL(Self.xaiAPIBase) else {
                return .failure("Invalid xAI base URL.")
            }
            return await testOpenAICompatible(base: base, apiKey: key, label: "xAI")
        case .anthropic:
            guard let key = anthropicAPIKey() else { return .failure("Add an Anthropic API key.") }
            guard let base = Self.normalizeBaseURL(Self.anthropicAPIBase) else {
                return .failure("Invalid Anthropic base URL.")
            }
            return await testAnthropic(base: base, apiKey: key)
        case .remoteOpenAI:
            guard let key = remoteOpenAIAPIKey() else {
                return .failure("Add an API key for this remote endpoint.")
            }
            guard let base = Self.normalizeBaseURL(remoteOpenAIBaseURL) else {
                return .failure("Enter a valid http(s) base URL (Tailscale MagicDNS, Funnel, OpenRouter, etc.).")
            }
            return await testOpenAICompatible(base: base, apiKey: key, label: "Remote")
        }
    }

    private func testOllama() async -> ConnectionTestResult {
        guard let base = Self.normalizeBaseURL(ollamaBaseURL) else {
            return .failure("Enter a valid http(s) Ollama URL (localhost or Tailscale).")
        }
        let url = base.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No HTTP response from Ollama.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("Ollama HTTP \(http.statusCode): \(body.prefix(160))")
            }
            let count = Self.modelCount(fromOpenAIStyle: data) // Ollama uses "models" array differently
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }.prefix(4)
                let suffix = names.isEmpty ? "" : " — \(names.joined(separator: ", "))"
                return .ok("Reachable · \(models.count) model\(models.count == 1 ? "" : "s")\(suffix)")
            }
            return .ok(count.map { "Reachable · \($0) models" } ?? "Reachable")
        } catch {
            return .failure(Self.connectionErrorMessage(error))
        }
    }

    private func testOpenAICompatible(base: URL, apiKey: String, label: String) async -> ConnectionTestResult {
        let url = base.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No HTTP response from \(label).")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure("\(label) rejected the API key (HTTP \(http.statusCode)).")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("\(label) HTTP \(http.statusCode): \(body.prefix(160))")
            }
            if let count = Self.modelCount(fromOpenAIStyle: data) {
                return .ok("\(label) reachable · \(count) model\(count == 1 ? "" : "s") listed")
            }
            return .ok("\(label) reachable")
        } catch {
            return .failure(Self.connectionErrorMessage(error))
        }
    }

    private func testAnthropic(base: URL, apiKey: String) async -> ConnectionTestResult {
        let url = base.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No HTTP response from Anthropic.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure("Anthropic rejected the API key (HTTP \(http.statusCode)).")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("Anthropic HTTP \(http.statusCode): \(body.prefix(160))")
            }
            if let count = Self.modelCount(fromOpenAIStyle: data) {
                return .ok("Anthropic reachable · \(count) model\(count == 1 ? "" : "s") listed")
            }
            return .ok("Anthropic reachable")
        } catch {
            return .failure(Self.connectionErrorMessage(error))
        }
    }

    private static func modelCount(fromOpenAIStyle data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [Any]
        else { return nil }
        return dataArr.count
    }

    private static func connectionErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return "Timed out — check the host is on Tailscale / running."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "Cannot reach host — check URL, VPN, or Tailscale."
            case NSURLErrorNotConnectedToInternet:
                return "No network connection."
            default:
                break
            }
        }
        return error.localizedDescription
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
