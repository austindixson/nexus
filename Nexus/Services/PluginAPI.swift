import Foundation
import AppKit

/// Minimal local plugin surface — Swift plugins + vault `.nexusplugin` bundles.
/// Bundle plugins are declarative JSON (commands / post-processors / templates) —
/// no network sandbox escape hatches.
protocol NexusPlugin: AnyObject {
    var id: String { get }
    var name: String { get }
    var version: String { get }
    func activate(api: PluginContext) async
    func deactivate() async
}

@MainActor
final class PluginContext {
    weak var app: AppState?
    private(set) var commands: [PluginCommand] = []
    private(set) var markdownPostProcessors: [(String) -> String] = []

    init(app: AppState) {
        self.app = app
    }

    func clearRegistrations() {
        commands.removeAll()
        markdownPostProcessors.removeAll()
    }

    func registerCommand(id: String, title: String, action: @escaping () -> Void) {
        commands.removeAll { $0.id == id }
        commands.append(PluginCommand(id: id, title: title, action: action))
    }

    func registerMarkdownPostProcessor(_ processor: @escaping (String) -> String) {
        markdownPostProcessors.append(processor)
    }

    func openNote(path: String) {
        app?.openNote(path: path)
    }

    func getActiveFile() -> String? {
        app?.selectedPath
    }

    func getVaultNotes() -> [String: NoteDocument] {
        app?.vault.notes ?? [:]
    }

    func insertText(_ text: String) {
        app?.insertTemplate(text)
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Run all post-processors over markdown body (preview path).
    func processMarkdown(_ markdown: String) -> String {
        markdownPostProcessors.reduce(markdown) { partial, fn in fn(partial) }
    }
}

struct PluginCommand: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

// MARK: - Bundle manifest (declarative .nexusplugin)

struct NexusPluginManifest: Codable {
    var id: String
    var name: String
    var version: String
    var commands: [ManifestCommand]?
    var postProcessors: [ManifestPostProcessor]?
    var templates: [ManifestTemplate]?

    struct ManifestCommand: Codable {
        var id: String
        var title: String
        /// "alert" | "insert" | "open" | "daily"
        var action: String
        var message: String?
        var text: String?
        var path: String?
    }

    struct ManifestPostProcessor: Codable {
        var pattern: String
        var replacement: String
        var caseInsensitive: Bool?
    }

    struct ManifestTemplate: Codable {
        var id: String
        var title: String
        var body: String
    }
}

/// Loads a declarative plugin from a `.nexusplugin` directory (manifest.json).
final class BundleNexusPlugin: NexusPlugin {
    let id: String
    let name: String
    let version: String
    private let manifest: NexusPluginManifest
    private let bundleURL: URL
    private var context: PluginContext?

    init?(bundleURL: URL) {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(NexusPluginManifest.self, from: data)
        else { return nil }
        self.bundleURL = bundleURL
        self.manifest = manifest
        self.id = manifest.id
        self.name = manifest.name
        self.version = manifest.version
    }

    @MainActor
    func activate(api: PluginContext) async {
        context = api
        for cmd in manifest.commands ?? [] {
            let c = cmd
            api.registerCommand(id: "\(id).\(c.id)", title: "\(name): \(c.title)") {
                Self.run(command: c, api: api)
            }
        }
        for t in manifest.templates ?? [] {
            let body = t.body
            api.registerCommand(id: "\(id).tpl.\(t.id)", title: "\(name): Insert \(t.title)") {
                api.insertText(body)
            }
        }
        for pp in manifest.postProcessors ?? [] {
            guard let regex = try? NSRegularExpression(
                pattern: pp.pattern,
                options: (pp.caseInsensitive ?? true) ? [.caseInsensitive] : []
            ) else { continue }
            let replacement = pp.replacement
            api.registerMarkdownPostProcessor { markdown in
                let ns = markdown as NSString
                let range = NSRange(location: 0, length: ns.length)
                return regex.stringByReplacingMatches(in: markdown, options: [], range: range, withTemplate: replacement)
            }
        }
    }

    func deactivate() async {
        context = nil
    }

    @MainActor
    private static func run(command: NexusPluginManifest.ManifestCommand, api: PluginContext) {
        switch command.action {
        case "alert":
            api.showAlert(title: command.title, message: command.message ?? "")
        case "insert":
            if let text = command.text { api.insertText(text) }
        case "open":
            if let path = command.path { api.openNote(path: path) }
        case "daily":
            api.app?.openDailyNote()
        default:
            api.showAlert(title: command.title, message: command.message ?? "Unknown action: \(command.action)")
        }
    }
}

// MARK: - Host

@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var plugins: [String: NexusPlugin] = [:]
    @Published private(set) var loadedBundlePaths: [String] = []
    private var context: PluginContext?
    private var builtInRegistered = false

    func attach(app: AppState) {
        context = PluginContext(app: app)
    }

    func register(_ plugin: NexusPlugin) async {
        guard let context else { return }
        if let existing = plugins[plugin.id] {
            await existing.deactivate()
        }
        plugins[plugin.id] = plugin
        await plugin.activate(api: context)
    }

    func unregister(id: String) async {
        if let plugin = plugins.removeValue(forKey: id) {
            await plugin.deactivate()
        }
        loadedBundlePaths.removeAll { $0.contains(id) }
    }

    var allCommands: [PluginCommand] {
        context?.commands ?? []
    }

    var markdownProcessor: (String) -> String {
        { [weak self] md in
            self?.context?.processMarkdown(md) ?? md
        }
    }

    /// Register built-ins once, then load `.nexusplugin` bundles from vault.
    func bootstrap(for vaultRoot: URL?) async {
        guard let context else { return }
        // Rebuild command list from scratch each vault switch
        context.clearRegistrations()
        plugins.removeAll()
        loadedBundlePaths.removeAll()
        builtInRegistered = false

        await register(SampleWordCountPlugin())
        builtInRegistered = true

        guard let vaultRoot else { return }
        await loadBundles(from: vaultRoot)
    }

    func reloadBundles(from vaultRoot: URL?) async {
        guard let vaultRoot else { return }
        // Drop only bundle plugins; keep built-ins
        let bundleIDs = plugins.compactMap { ($0.value is BundleNexusPlugin) ? $0.key : nil }
        for id in bundleIDs {
            await unregister(id: id)
        }
        // Re-activate built-ins' commands after clear
        if let context {
            context.clearRegistrations()
            for plugin in plugins.values {
                await plugin.activate(api: context)
            }
        }
        await loadBundles(from: vaultRoot)
    }

    private func loadBundles(from vaultRoot: URL) async {
        let candidates = [
            vaultRoot.appendingPathComponent(".nexus/plugins", isDirectory: true),
            vaultRoot.appendingPathComponent("plugins", isDirectory: true),
        ]
        let fm = FileManager.default
        for dir in candidates {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items {
                let manifestPath = url.appendingPathComponent("manifest.json").path
                guard fm.fileExists(atPath: manifestPath) else { continue }
                guard let plugin = BundleNexusPlugin(bundleURL: url) else { continue }
                await register(plugin)
                loadedBundlePaths.append(url.path)
            }
        }
    }
}

/// Example built-in plugin demonstrating the API.
final class SampleWordCountPlugin: NexusPlugin {
    let id = "nexus.sample.wordcount"
    let name = "Word Count"
    let version = "1.0.0"
    private var context: PluginContext?

    @MainActor
    func activate(api: PluginContext) async {
        context = api
        api.registerCommand(id: "word-count", title: "Word count: show for active note") {
            guard let path = api.getActiveFile(),
                  let note = api.getVaultNotes()[path]
            else { return }
            let words = note.content.split { $0.isWhitespace || $0.isNewline }.count
            api.showAlert(title: "Word Count", message: "\(note.title): \(words) words")
        }
    }

    func deactivate() async {
        context = nil
    }
}
