import Foundation
import Security

/// Reads existing Claude Code / Codex CLI credentials from disk or Keychain.
/// Never logs token values. Does not copy secrets into Nexus Keychain.
enum CLICredentialStore {
    struct ClaudeCodeOAuth: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            // Small skew so we don't race the exact expiry second.
            return Date() >= expiresAt.addingTimeInterval(-60)
        }
    }

    enum CodexCredential: Sendable, Equatable {
        /// Platform API key from auth.json (`OPENAI_API_KEY`).
        case apiKey(String)
        /// ChatGPT subscription OAuth used by Codex CLI.
        case chatgptOAuth(accessToken: String, accountID: String, refreshToken: String?)
    }

    enum DetectionStatus: Equatable {
        case missing
        case available(String)
        case expired(String)
    }

    // MARK: - Live detection

    static func claudeCodeSession(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeCodeOAuth? {
        if let fromKeychain = loadClaudeFromKeychain(), !fromKeychain.isExpired {
            return fromKeychain
        }
        let fileURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: fileURL),
              let session = parseClaudeCredentials(data: data),
              !session.isExpired
        else { return nil }
        return session
    }

    static func codexSession(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexCredential? {
        let fileURL = homeDirectory.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return parseCodexAuth(data: data)
    }

    static func claudeCodeStatus(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DetectionStatus {
        if let fromKeychain = loadClaudeFromKeychain() {
            if fromKeychain.isExpired {
                return .expired("Claude Code login expired — run `claude` to refresh.")
            }
            return .available("Claude Code login detected")
        }
        let fileURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: fileURL),
              let session = parseClaudeCredentials(data: data)
        else { return .missing }
        if session.isExpired {
            return .expired("Claude Code login expired — run `claude` to refresh.")
        }
        return .available("Claude Code login detected")
    }

    static func codexStatus(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DetectionStatus {
        let fileURL = homeDirectory.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: fileURL),
              let cred = parseCodexAuth(data: data)
        else { return .missing }
        switch cred {
        case .apiKey:
            return .available("Codex CLI API key detected")
        case .chatgptOAuth:
            return .available("Codex CLI ChatGPT login detected")
        }
    }

    // MARK: - Project .env (e.g. CLM)

    /// Default path used when Settings has not overridden the CLM / project env file.
    static let defaultCLMEnvPath =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/CLM/.env")
            .path

    static func parseEnvFile(data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    static func envFileValue(key: String, path: String) -> String? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let map = parseEnvFile(data: data)
        guard let value = map[key], !value.isEmpty else { return nil }
        return value
    }

    static func clmEnvStatus(path: String) -> DetectionStatus {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: expanded) else { return .missing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else {
            return .missing
        }
        let map = parseEnvFile(data: data)
        var found: [String] = []
        if let v = map["DEEPSEEK_API_KEY"], !v.isEmpty { found.append("DEEPSEEK_API_KEY") }
        if let v = map["OPENAI_API_KEY"], !v.isEmpty { found.append("OPENAI_API_KEY") }
        if let v = map["ANTHROPIC_API_KEY"], !v.isEmpty { found.append("ANTHROPIC_API_KEY") }
        if found.isEmpty {
            return .available("Env file found (no known AI keys)")
        }
        return .available("Env file: \(found.joined(separator: ", "))")
    }

    // MARK: - Parsers (testable)

    static func parseClaudeCredentials(data: Data) -> ClaudeCodeOAuth? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // File shape: { "claudeAiOauth": { accessToken, refreshToken, expiresAt } }
        // Keychain may store the same object or the inner oauth object alone.
        let oauth: [String: Any]
        if let nested = json["claudeAiOauth"] as? [String: Any] {
            oauth = nested
        } else if json["accessToken"] != nil {
            oauth = json
        } else {
            return nil
        }
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        let expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            // Claude Code stores ms since epoch.
            expiresAt = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000.0 : ms)
        } else if let ms = oauth["expiresAt"] as? Int {
            let v = Double(ms)
            expiresAt = Date(timeIntervalSince1970: v > 1e12 ? v / 1000.0 : v)
        } else {
            expiresAt = nil
        }
        return ClaudeCodeOAuth(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    static func parseCodexAuth(data: Data) -> CodexCredential? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let key = json["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return .apiKey(key)
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else { return nil }
        let accountID = (tokens["account_id"] as? String)
            ?? (json["account_id"] as? String)
            ?? ""
        guard !accountID.isEmpty else { return nil }
        let refresh = tokens["refresh_token"] as? String
        return .chatgptOAuth(accessToken: access, accountID: accountID, refreshToken: refresh)
    }

    // MARK: - Keychain (Claude Code)

    private static func loadClaudeFromKeychain() -> ClaudeCodeOAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        // Value may be JSON or a UTF-8 string wrapping JSON.
        if let session = parseClaudeCredentials(data: data) {
            return session
        }
        if let text = String(data: data, encoding: .utf8),
           let textData = text.data(using: .utf8) {
            return parseClaudeCredentials(data: textData)
        }
        return nil
    }
}
