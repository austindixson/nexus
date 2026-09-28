import SwiftUI
import AppKit

@main
struct NexusApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            NexusCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if UserDefaults.standard.object(forKey: "nexus.appearance") == nil {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

struct NexusCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject private var hotkeys = HotkeyService.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { appState.createNote() }
                .keyboardShortcut(hotkeys.chord(for: "newNote").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "newNote").modifiers)

            Button("New Folder…") { appState.createFolder() }
                .keyboardShortcut(hotkeys.chord(for: "newFolder").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "newFolder").modifiers)

            Divider()

            Button("Open Vault…") { appState.openVaultPanel() }
                .keyboardShortcut(hotkeys.chord(for: "openVault").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "openVault").modifiers)

            Button("Open Daily Note") { appState.openDailyNote() }
                .keyboardShortcut(hotkeys.chord(for: "dailyNote").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "dailyNote").modifiers)
        }

        CommandGroup(after: .textEditing) {
            Button("Command Palette…") { appState.showCommandPalette = true }
                .keyboardShortcut(hotkeys.chord(for: "commandPalette").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "commandPalette").modifiers)

            Button("Quick Switcher…") { appState.showQuickSwitcher = true }
                .keyboardShortcut(hotkeys.chord(for: "quickSwitcher").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "quickSwitcher").modifiers)

            Button("Search in Vault…") { appState.focusSearch() }
                .keyboardShortcut(hotkeys.chord(for: "searchVault").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "searchVault").modifiers)
        }

        CommandMenu("View") {
            Button("Toggle Left Sidebar") { appState.toggleLeftSidebar() }
                .keyboardShortcut(hotkeys.chord(for: "toggleLeft").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "toggleLeft").modifiers)

            Button("Toggle Right Sidebar") { appState.toggleRightSidebar() }
                .keyboardShortcut(hotkeys.chord(for: "toggleRight").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "toggleRight").modifiers)

            Divider()

            Button("Editor") { appState.mainMode = .editor }
                .keyboardShortcut(hotkeys.chord(for: "modeEditor").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "modeEditor").modifiers)

            Button("Graph View") { appState.mainMode = .graph }
                .keyboardShortcut(hotkeys.chord(for: "modeGraph").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "modeGraph").modifiers)

            Button("Local Graph") { appState.openLocalGraph() }
                .keyboardShortcut(hotkeys.chord(for: "modeLocalGraph").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "modeLocalGraph").modifiers)

            Button("Canvas") { appState.mainMode = .canvas }
                .keyboardShortcut(hotkeys.chord(for: "modeCanvas").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "modeCanvas").modifiers)

            Divider()

            Button("Source Mode") { appState.editorMode = .source }
            Button("Live Preview") { appState.editorMode = .livePreview }
            Button("Split View") { appState.editorMode = .split }
        }

        CommandMenu("Graph") {
            Button("Global Graph") {
                appState.mainMode = .graph
                appState.graphMode = .global
            }
            Button("Local Graph") { appState.openLocalGraph() }
            Divider()
            Button("Reset Graph Camera") { appState.graphResetCamera = UUID() }
            Button("Reheat Layout") { appState.graphReheat = UUID() }
        }

        CommandMenu("Nexus") {
            Button("Ask Nexus…") { appState.focusAskNexus() }
                .keyboardShortcut(hotkeys.chord(for: "askNexus").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "askNexus").modifiers)

            Button("Import Source…") { appState.showImportSheet = true }
                .keyboardShortcut(hotkeys.chord(for: "importSource").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "importSource").modifiers)

            Divider()

            Button("Rebuild Vault Index") { appState.vault.fullRescan() }
                .keyboardShortcut(hotkeys.chord(for: "rebuildIndex").keyEquivalent,
                                  modifiers: hotkeys.chord(for: "rebuildIndex").modifiers)

            Button("Reload Plugins") {
                Task { await appState.reloadPlugins() }
            }
        }
    }
}
