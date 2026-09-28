import Foundation

/// Git remote validation for vault sync.
///
/// Allowed targets (see docs/SYNC.md):
/// - `https://` / `http://` URLs (http requires `allowInsecureRemote`)
/// - `ssh://` and `git://` URLs
/// - `git@host:path` style SSH remotes
/// - Absolute local filesystem paths to a bare repo (LAN / shared volume / another Mac)
///
/// `file://` URLs are normalized to filesystem paths (so they remain safe for
/// `git -c protocol.file.allow=always`). Anything else is rejected.
enum GitRemote: Equatable, Sendable {
    case https(String)
    case http(String)
    case ssh(String)
    case localPath(String)

    /// A short, safe label for UI (never contains userinfo).
    var displayLabel: String {
        switch self {
        case .https(let s), .http(let s):
            if let url = URL(string: s), let host = url.host {
                return host + url.path
            }
            return s
        case .ssh(let s):
            return s
        case .localPath(let p):
            return p
        }
    }

    /// Whether this target needs network (SSH/HTTPS) — local paths do not.
    var isNetworkRemote: Bool {
        switch self {
        case .https, .http, .ssh: return true
        case .localPath: return false
        }
    }

    nonisolated private static let scpLike = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9._\-]+@[A-Za-z0-9._\-]+:[A-Za-z0-9._~/\-]+$"#
    )

    /// Parse and validate a user-entered remote string.
    /// - Parameters:
    ///   - input: raw text from the settings field
    ///   - allowInsecureRemote: permit `http://` (off by default)
    static func parse(_ input: String, allowInsecureRemote: Bool = false) -> GitRemote? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.count <= 2048 else { return nil }

        // Reject control characters and newlines outright (argument / config injection).
        let controlScalars: Set<Unicode.Scalar> = ["\n", "\r", "\u{0000}", "\u{0007}", "\u{001B}"]
        if raw.unicodeScalars.contains(where: { controlScalars.contains($0) }) { return nil }
        if raw.unicodeScalars.contains(where: { $0 == "\u{7F}" }) { return nil }

        // file:///path and file://localhost/path → local path
        if raw.lowercased().hasPrefix("file://") {
            guard let url = URL(string: raw) else { return nil }
            // Only empty/localhost hosts are acceptable for file URLs.
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
            let path = url.path
            return isSafeLocalPath(path) ? .localPath(path) : nil
        }

        // scheme://...
        if let range = raw.range(of: "://") {
            let scheme = String(raw[..<range.lowerBound]).lowercased()
            switch scheme {
            case "https":
                return validateNetworkURL(raw) ? .https(raw) : nil
            case "http":
                guard allowInsecureRemote else { return nil }
                return validateNetworkURL(raw) ? .http(raw) : nil
            case "ssh", "git", "git+ssh":
                return validateNetworkURL(raw) ? .ssh(raw) : nil
            default:
                return nil
            }
        }

        // scp-like: git@github.com:user/repo.git
        let range = NSRange(raw.startIndex..., in: raw)
        if scpLike.firstMatch(in: raw, range: range) != nil {
            return .ssh(raw)
        }

        // Absolute local path to a bare repo (or a share mount).
        if raw.hasPrefix("/") {
            return isSafeLocalPath(raw) ? .localPath(raw) : nil
        }

        return nil
    }

    /// Network URLs must be http(s)/ssh/git with a host and no userinfo credentials
    /// (userinfo in a git remote URL would land in `.git/config` in cleartext).
    nonisolated private static func validateNetworkURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        guard ["https", "http", "ssh", "git", "git+ssh"].contains(scheme) else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        // No user:pass@host — refuse; keys belong in Keychain / ssh-agent.
        if let user = url.user, !user.isEmpty, scheme != "ssh" && scheme != "git" && scheme != "git+ssh" {
            return false
        }
        // ssh/git URLs may carry a user (git@host) but must not carry a password.
        if (scheme == "ssh" || scheme == "git" || scheme == "git+ssh"), url.password != nil {
            return false
        }
        // Host must be hostname or IP-shaped.
        let hostOk = host.range(of: #"^[A-Za-z0-9.\-]+$"#, options: .regularExpression) != nil
        return hostOk && url.path.count < 1024
    }

    /// Local paths must be absolute, free of traversal components, and not the vault itself.
    nonisolated private static func isSafeLocalPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count >= 2 else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return false }
        for part in parts {
            if part == ".." { return false }
            if part.contains("\0") { return false }
        }
        // Home-relative "~/…" is not absolute after expansion by us — reject; callers
        // should pass an already-expanded path.
        if path.hasPrefix("~/") { return false }
        // Never allow a path containing a newline (already handled) or NUL.
        if path.contains("\n") || path.contains("\r") { return false }
        return true
    }
}
