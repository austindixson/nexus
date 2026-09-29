import Foundation

/// iCloud Drive / ubiquitous-file helpers for vault friendliness.
enum CloudVaultSupport {
    /// Names that should never appear as notes in the tree.
    static func shouldSkipFile(name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        // iCloud not-downloaded placeholders
        if name.hasPrefix(".") && name.hasSuffix(".icloud") { return true }
        if name.hasSuffix(".icloud") { return true }
        // Temp / partial download debris
        if name.hasSuffix(".tmp") || name.hasSuffix(".download") || name.hasSuffix(".part") {
            return true
        }
        // Office lock files
        if name.hasPrefix("~$") { return true }
        return false
    }

    /// Detect common conflict-copy naming from iCloud / Finder.
    static func isConflictCopy(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("conflicted copy") { return true }
        if lower.contains("'s conflicted copy") { return true }
        // "Note 2.md" alone is ambiguous; require conflict markers or iCloud-style
        if lower.range(of: #" \(\d+\)$"#, options: .regularExpression) != nil
            && lower.contains("conflict") {
            return true
        }
        // macOS sometimes: "filename 2.ext" after simultaneous edits — flag numeric suffix before extension
        // when a sibling base exists (caller can refine). Here: "Name 2.md" pattern only if ends with " 2.md" etc.
        if lower.range(of: #" \d+\.(md|markdown|canvas)$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func isUbiquitousItem(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// Best-effort download of an iCloud file before reading.
    static func ensureDownloaded(at url: URL) {
        guard isUbiquitousItem(at: url) else { return }
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ])
        if let status = values?.ubiquitousItemDownloadingStatus,
           status == .current {
            return
        }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Non-fatal — reader may still fail and skip.
        }
    }

    /// Whether vault root appears to live under iCloud Drive.
    static func isLikelyICloudVault(_ root: URL) -> Bool {
        if isUbiquitousItem(at: root) { return true }
        let path = root.path
        if path.contains("Library/Mobile Documents/") { return true }
        if path.contains("iCloud Drive") || path.contains("Mobile Documents") { return true }
        if path.contains("com~apple~CloudDocs") { return true }
        return false
    }

    /// Debounce interval for FSEvents — longer on iCloud to absorb download storms.
    static func rescanDebounceNanoseconds(for root: URL?) -> UInt64 {
        guard let root, isLikelyICloudVault(root) else {
            return 250_000_000 // 0.25s
        }
        return 900_000_000 // 0.9s
    }

    /// Atomic write that plays nicer with file providers: write temp beside target, then replace.
    static func atomicWrite(_ content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).nexus-tmp-\(UUID().uuidString)")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        // Clean tmp if replace left it
        try? fm.removeItem(at: tmp)
    }
}
