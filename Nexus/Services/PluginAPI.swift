import Foundation

/// Minimal local plugin surface — Swift plugins can register commands and hooks.
/// Community JS plugins are intentionally not sandboxed network code; plugins are
/// in-process Swift modules or future `.nexusplugin` bundles loaded from the vault.
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

    func registerCommand(id: String, title: String, action: @escaping () -> Void) {
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
}

struct PluginCommand: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var plugins: [String: NexusPlugin] = [:]
    private var context: PluginContext?

    func attach(app: AppState) {
        context = PluginContext(app: app)
    }

    func register(_ plugin: NexusPlugin) async {
        guard let context else { return }
        plugins[plugin.id] = plugin
        await plugin.activate(api: context)
    }

    func unregister(id: String) async {
        if let plugin = plugins.removeValue(forKey: id) {
            await plugin.deactivate()
        }
    }

    var allCommands: [PluginCommand] {
        context?.commands ?? []
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
            let alert = NSAlert()
            alert.messageText = "Word Count"
            alert.informativeText = "\(note.title): \(words) words"
            alert.runModal()
        }
    }

    func deactivate() async {
        context = nil
    }
}

import AppKit
