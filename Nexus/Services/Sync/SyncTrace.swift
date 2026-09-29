import Foundation

/// Append-only trace of git commands the sync engine actually ran.
/// Diagnostics only — never contains secret values.
///
/// Enabled when `NEXUS_SYNC_TRACE` is set (path to the log file). In DEBUG
/// builds a `/tmp` fallback is used so empty-output pull errors still have a
/// recent trail when xcodebuild strips the env var from the test runner.
enum SyncTrace {
    nonisolated private static var targetPath: String? {
        if let explicit = ProcessInfo.processInfo.environment["NEXUS_SYNC_TRACE"] {
            return explicit.isEmpty ? nil : explicit
        }
        #if DEBUG
        return "/tmp/nexus-sync-trace.log"
        #else
        return nil
        #endif
    }

    /// Logs regardless of any success/failure filtering the caller applies.
    nonisolated static func logFull(_ message: String) {
        log(message)
    }

    nonisolated static func log(_ message: String) {
        guard let path = targetPath else { return }
        let tid = String(format: "%0x", UInt(bitPattern: ObjectIdentifier(Thread.current).hashValue & 0xFFFF_FFFF))
        let line = "\(Date()) [\(tid)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Last `n` trace lines, newest last. Empty when the trace file is absent.
    nonisolated static func tail(_ n: Int = 40) -> [String] {
        guard let path = targetPath,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(n))
    }
}
