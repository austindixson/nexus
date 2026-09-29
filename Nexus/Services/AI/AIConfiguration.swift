import Foundation
import Security

/// AI settings: opt-in, Keychain-backed keys, provider selection.
/// Vault opens and works fully with AI disabled (local-first guarantee).
/// Also reuses local Claude Code / Codex CLI OAuth and optional project `.env` keys
/// (e.g. `~/Desktop/CLM/.env`) without copying secrets into Nexus Keychain.
@MainActor
final class AIConfiguration: ObservableObject {
    static let shared = AIConfiguration()

    enum ProviderKind: String, CaseIterable, Identifiable, Hashable {
        case disabled
        case openai
        case xai
        case anthropic
        case deepseek
        case ollama
        case remoteOpenAI

        var id: String { rawValue }

        var title: String {
            switch self {
            case .disabled: return "Disabled (offline)"
            case .openai: return "OpenAI"
            case .xai: return "SpaceXAI (xAI)"
            case .anthropic: return "Anthropic (Claude)"
            case .deepseek: return "DeepSeek"
            case .ollama: return "Ollama"
            case .remoteOpenAI: return "Remote OpenAI-compatible"
            }
        }

        /// Cloud / remote gateways need some credential before Ask is live.
        var requiresAPIKey: Bool {
            switch self {
            case .disabled, .ollama: return false
            case .openai, .xai, .anthropic, .deepseek, .remoteOpenAI: return true
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

    /// Where the active credential came from (for UI status).
    enum CredentialSource: Equatable {
        case none
        case keychain
        case environment
        case claudeCodeCLI
        case codexCLI
        case clmEnv
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

    /// When no Nexus Keychain key is set, reuse Claude Code / Codex CLI logins and CLM `.env`.
    @Published var useLocalCredentials: Bool {
        didSet {
            guard isConfigured else { return }
            UserDefaults.standard.set(useLocalCredentials, forKey: Keys.useLocalCredentials)
            refreshKeyFlags()
        }
    }

    /// Path to a project `.env` (default `~/Desktop/CLM/.env`) for `DEEPSEEK_API_KEY` etc.
    @Published var clmEnvPath: String {
        didSet {
            guard isConfigured else { return }
            UserDefaults.standard.set(clmEnvPath, forKey: Keys.clmEnvPath)
            refreshKeyFlags()
        }
    }

    /// Gates didSet side-effects until `init` finishes.
    private var isConfigured = false

    /// In-memory only mirror; never write API keys to vault files.
    @Published private(set) var hasXAIKey: Bool = false
    @Published private(set) var hasOpenAIKey: Bool = false
    @Published private(set) var hasAnthropicKey: Bool = false
    @Published private(set) var hasDeepSeekKey: Bool = false
    @Published private(set) var hasRemoteOpenAIKey: Bool = false
    @Published private(set) var hasCodexCLI: Bool = false
    @Published private(set) var hasClaudeCodeCLI: Bool = false
    @Published private(set) var hasCLMEnv: Bool = false
    @Published private(set) var claudeCodeStatusText: String = ""
    @Published private(set) var codexStatusText: String = ""
    @Published private(set) var clmEnvStatusText: String = ""

    var isEnabled: Bool {
        switch providerKind {
        case .disabled: return false
        case .openai: return resolveOpenAI() != nil
        case .xai: return hasXAIKey
        case .anthropic: return resolveAnthropic() != nil
        case .deepseek: return resolveDeepSeek() != nil
        case .ollama: return true
        case .remoteOpenAI: return hasRemoteOpenAIKey
        }
    }

    /// Human-readable active credential source for Ask status capsule.
    var activeCredentialLabel: String? {
        switch providerKind {
        case .openai:
            switch resolveOpenAI() {
            case .apiKey(_, let source):
                return source == .codexCLI ? "Codex CLI" : (source == .clmEnv ? "CLM .env" : nil)
            case .codexOAuth: return "Codex"
            case .none: return nil
            }
        case .anthropic:
            switch resolveAnthropic() {
            case .apiKey(_, let source):
                return source == .clmEnv ? "CLM .env" : nil
            case .claudeCodeOAuth: return "Claude Code"
            case .none: return nil
            }
        case .deepseek:
            if case .some((_, let source)) = resolveDeepSeek() {
                return source == .clmEnv ? "CLM .env" : (source == .environment ? "env" : nil)
            }
            return nil
        default:
            return nil
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
        static let useLocalCredentials = "nexus.ai.useLocalCredentials"
        static let clmEnvPath = "nexus.ai.clmEnvPath"
        static let xaiKeychain = "nexus.ai.xai.apiKey"
        static let openAIKeychain = "nexus.ai.openai.apiKey"
        static let anthropicKeychain = "nexus.ai.anthropic.apiKey"
        static let deepSeekKeychain = "nexus.ai.deepseek.apiKey"
        static let remoteOpenAIKeychain = "nexus.ai.remote.apiKey"
    }

    static let openAIAPIBase = "https://api.openai.com/v1"
    static let xaiAPIBase = "https://api.x.ai/v1"
    static let anthropicAPIBase = "https://api.anthropic.com"
    static let deepSeekAPIBase = "https://api.deepseek.com/v1"

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

        if UserDefaults.standard.object(forKey: Keys.useLocalCredentials) == nil {
            useLocalCredentials = true
        } else {
            useLocalCredentials = UserDefaults.standard.bool(forKey: Keys.useLocalCredentials)
        }
        clmEnvPath = UserDefaults.standard.string(forKey: Keys.clmEnvPath)
            ?? CLICredentialStore.defaultCLMEnvPath

        isConfigured = true
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

        let openAIKeychain = KeychainHelper.load(account: Keys.openAIKeychain) != nil
            || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        hasOpenAIKey = openAIKeychain

        hasAnthropicKey = KeychainHelper.load(account: Keys.anthropicKeychain) != nil
            || ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil

        hasDeepSeekKey = KeychainHelper.load(account: Keys.deepSeekKeychain) != nil
            || ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] != nil

        hasRemoteOpenAIKey = KeychainHelper.load(account: Keys.remoteOpenAIKeychain) != nil
            || KeychainHelper.load(account: Keys.openAIKeychain) != nil
            || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil

        let claudeStatus = CLICredentialStore.claudeCodeStatus()
        let codexStatus = CLICredentialStore.codexStatus()
        let envStatus = CLICredentialStore.clmEnvStatus(path: clmEnvPath)

        hasClaudeCodeCLI = {
            if case .available = claudeStatus { return true }
            return false
        }()
        hasCodexCLI = {
            if case .available = codexStatus { return true }
            return false
        }()
        hasCLMEnv = {
            if case .available(let msg) = envStatus { return msg.contains("DEEPSEEK") || msg.contains("OPENAI") || msg.contains("ANTHROPIC") }
            return false
        }()

        switch claudeStatus {
        case .missing: claudeCodeStatusText = "No Claude Code login"
        case .available(let m): claudeCodeStatusText = m
        case .expired(let m): claudeCodeStatusText = m
        }
        switch codexStatus {
        case .missing: codexStatusText = "No Codex CLI login"
        case .available(let m): codexStatusText = m
        case .expired(let m): codexStatusText = m
        }
        switch envStatus {
        case .missing: clmEnvStatusText = "CLM .env not found"
        case .available(let m): clmEnvStatusText = m
        case .expired(let m): clmEnvStatusText = m
        }

        // Local credentials also satisfy "has key" for enablement UX when toggle is on.
        if useLocalCredentials {
            if hasCodexCLI { hasOpenAIKey = true }
            if hasClaudeCodeCLI { hasAnthropicKey = true }
            if CLICredentialStore.envFileValue(key: "DEEPSEEK_API_KEY", path: clmEnvPath) != nil {
                hasDeepSeekKey = true
            }
            if CLICredentialStore.envFileValue(key: "OPENAI_API_KEY", path: clmEnvPath) != nil {
                hasOpenAIKey = true
            }
            if CLICredentialStore.envFileValue(key: "ANTHROPIC_API_KEY", path: clmEnvPath) != nil {
                hasAnthropicKey = true
            }
        }
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

    func setDeepSeekKey(_ key: String?) {
        saveKey(key, account: Keys.deepSeekKeychain)
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

    func deepSeekAPIKey() -> String? {
        KeychainHelper.load(account: Keys.deepSeekKeychain)
            ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
    }

    func remoteOpenAIAPIKey() -> String? {
        KeychainHelper.load(account: Keys.remoteOpenAIKeychain)
            ?? KeychainHelper.load(account: Keys.openAIKeychain)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    // MARK: - Credential resolution

    private enum OpenAIResolved {
        case none
        case apiKey(String, CredentialSource)
        case codexOAuth(access: String, accountID: String)
    }

    private enum AnthropicResolved {
        case none
        case apiKey(String, CredentialSource)
        case claudeCodeOAuth(String)
    }

    private func resolveOpenAI() -> OpenAIResolved {
        if let key = KeychainHelper.load(account: Keys.openAIKeychain), !key.isEmpty {
            return .apiKey(key, .keychain)
        }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return .apiKey(key, .environment)
        }
        guard useLocalCredentials else { return .none }
        if let key = CLICredentialStore.envFileValue(key: "OPENAI_API_KEY", path: clmEnvPath) {
            return .apiKey(key, .clmEnv)
        }
        switch CLICredentialStore.codexSession() {
        case .apiKey(let key):
            return .apiKey(key, .codexCLI)
        case .chatgptOAuth(let access, let accountID, _):
            return .codexOAuth(access: access, accountID: accountID)
        case .none:
            return .none
        }
    }

    private func resolveAnthropic() -> AnthropicResolved {
        if let key = KeychainHelper.load(account: Keys.anthropicKeychain), !key.isEmpty {
            return .apiKey(key, .keychain)
        }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return .apiKey(key, .environment)
        }
        guard useLocalCredentials else { return .none }
        if let key = CLICredentialStore.envFileValue(key: "ANTHROPIC_API_KEY", path: clmEnvPath) {
            return .apiKey(key, .clmEnv)
        }
        if let session = CLICredentialStore.claudeCodeSession() {
            return .claudeCodeOAuth(session.accessToken)
        }
        return .none
    }

    private func resolveDeepSeek() -> (String, CredentialSource)? {
        if let key = KeychainHelper.load(account: Keys.deepSeekKeychain), !key.isEmpty {
            return (key, .keychain)
        }
        if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty {
            return (key, .environment)
        }
        guard useLocalCredentials else { return nil }
        if let key = CLICredentialStore.envFileValue(key: "DEEPSEEK_API_KEY", path: clmEnvPath) {
            return (key, .clmEnv)
        }
        return nil
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
            switch resolveOpenAI() {
            case .none:
                return nil
            case .apiKey(let key, _):
                guard let base = Self.normalizeBaseURL(Self.openAIAPIBase) else { return nil }
                return OpenAICompatibleProvider(
                    name: "OpenAI",
                    baseURL: base,
                    apiKey: key,
                    defaultModel: modelID.isEmpty ? "gpt-4o-mini" : modelID
                )
            case .codexOAuth(let access, let accountID):
                return CodexChatGPTProvider(
                    accessToken: access,
                    accountID: accountID,
                    defaultModel: modelID.isEmpty ? "gpt-5.4" : modelID
                )
            }
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
            guard let base = Self.normalizeBaseURL(Self.anthropicAPIBase) else { return nil }
            switch resolveAnthropic() {
            case .none:
                return nil
            case .apiKey(let key, _):
                return AnthropicProvider(
                    baseURL: base,
                    auth: .apiKey(key),
                    defaultModel: modelID.isEmpty ? "claude-sonnet-4-5" : modelID
                )
            case .claudeCodeOAuth(let token):
                return AnthropicProvider(
                    baseURL: base,
                    auth: .claudeCodeOAuth(token),
                    defaultModel: modelID.isEmpty ? "claude-sonnet-4-5" : modelID
                )
            }
        case .deepseek:
            guard let (key, _) = resolveDeepSeek() else { return nil }
            guard let base = Self.normalizeBaseURL(Self.deepSeekAPIBase) else { return nil }
            return OpenAICompatibleProvider(
                name: "DeepSeek",
                baseURL: base,
                apiKey: key,
                defaultModel: modelID.isEmpty ? "deepseek-chat" : modelID
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
            .deepseek: "deepseek-chat",
            .ollama: "llama3.2",
            .remoteOpenAI: "gpt-4o-mini",
        ]
        guard let next = defaults[kind] else { return }
        let previousDefaults = Set(defaults.values).union(["gpt-5.4"])
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
            switch resolveOpenAI() {
            case .none:
                return .failure("Add an OpenAI API key, or enable local Codex CLI / CLM .env credentials.")
            case .apiKey(let key, let source):
                guard let base = Self.normalizeBaseURL(Self.openAIAPIBase) else {
                    return .failure("Invalid OpenAI base URL.")
                }
                let label = source == .clmEnv ? "OpenAI (CLM .env)" : "OpenAI"
                return await testOpenAICompatible(base: base, apiKey: key, label: label)
            case .codexOAuth(let access, let accountID):
                return await CodexChatGPTProvider.testConnection(accessToken: access, accountID: accountID)
            }
        case .xai:
            guard let key = xaiAPIKey() else { return .failure("Add an xAI API key.") }
            guard let base = Self.normalizeBaseURL(Self.xaiAPIBase) else {
                return .failure("Invalid xAI base URL.")
            }
            return await testOpenAICompatible(base: base, apiKey: key, label: "xAI")
        case .anthropic:
            guard let base = Self.normalizeBaseURL(Self.anthropicAPIBase) else {
                return .failure("Invalid Anthropic base URL.")
            }
            switch resolveAnthropic() {
            case .none:
                return .failure("Add an Anthropic API key, or enable Claude Code CLI / CLM .env credentials.")
            case .apiKey(let key, _):
                return await testAnthropic(base: base, apiKey: key, oauth: false)
            case .claudeCodeOAuth(let token):
                return await testAnthropic(base: base, apiKey: token, oauth: true)
            }
        case .deepseek:
            guard let (key, source) = resolveDeepSeek() else {
                return .failure("Add a DeepSeek API key, or point CLM .env at DEEPSEEK_API_KEY.")
            }
            guard let base = Self.normalizeBaseURL(Self.deepSeekAPIBase) else {
                return .failure("Invalid DeepSeek base URL.")
            }
            let label = source == .clmEnv ? "DeepSeek (CLM .env)" : "DeepSeek"
            return await testOpenAICompatible(base: base, apiKey: key, label: label)
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
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }.prefix(4)
                let suffix = names.isEmpty ? "" : " — \(names.joined(separator: ", "))"
                return .ok("Reachable · \(models.count) model\(models.count == 1 ? "" : "s")\(suffix)")
            }
            return .ok("Reachable")
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

    private func testAnthropic(base: URL, apiKey: String, oauth: Bool) async -> ConnectionTestResult {
        let url = base.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if oauth {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("cli", forHTTPHeaderField: "x-app")
            req.setValue("claude-cli/1.0 (Nexus)", forHTTPHeaderField: "User-Agent")
        } else {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No HTTP response from Anthropic.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                let hint = oauth ? " Run `claude` to refresh." : ""
                return .failure("Anthropic rejected credentials (HTTP \(http.statusCode)).\(hint)")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("Anthropic HTTP \(http.statusCode): \(body.prefix(160))")
            }
            let label = oauth ? "Claude Code" : "Anthropic"
            if let count = Self.modelCount(fromOpenAIStyle: data) {
                return .ok("\(label) reachable · \(count) model\(count == 1 ? "" : "s") listed")
            }
            return .ok("\(label) reachable")
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
