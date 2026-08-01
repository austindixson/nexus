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
                .frame(width: 520, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        // Prefer dark glass aesthetic by default; user can override in Settings.
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                appState.createNote()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Folder…") {
                appState.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open Vault…") {
                appState.openVaultPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Open Daily Note") {
                appState.openDailyNote()
            }
            .keyboardShortcut("d", modifiers: [.command])
        }

        CommandGroup(after: .textEditing) {
            Button("Command Palette…") {
                appState.showCommandPalette = true
            }
            .keyboardShortcut("p", modifiers: [.command])

            Button("Quick Switcher…") {
                appState.showQuickSwitcher = true
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Search in Vault…") {
                appState.focusSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandMenu("View") {
            Button("Toggle Left Sidebar") {
                appState.toggleLeftSidebar()
            }
            .keyboardShortcut("1", modifiers: [.command, .option])

            Button("Toggle Right Sidebar") {
                appState.toggleRightSidebar()
            }
            .keyboardShortcut("2", modifiers: [.command, .option])

            Divider()

            Button("Editor") {
                appState.mainMode = .editor
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("Graph View") {
                appState.mainMode = .graph
            }
            .keyboardShortcut("g", modifiers: [.command, .option])

            Button("Local Graph") {
                appState.openLocalGraph()
            }
            .keyboardShortcut("g", modifiers: [.command, .option, .shift])

            Button("Canvas") {
                appState.mainMode = .canvas
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Divider()

            Button("Source Mode") {
                appState.editorMode = .source
            }
            Button("Live Preview") {
                appState.editorMode = .livePreview
            }
            Button("Split View") {
                appState.editorMode = .split
            }
        }

        CommandMenu("Graph") {
            Button("Global Graph") {
                appState.mainMode = .graph
                appState.graphMode = .global
            }
            Button("Local Graph") {
                appState.openLocalGraph()
            }
            Divider()
            Button("Reset Graph Camera") {
                appState.graphResetCamera = UUID()
            }
            Button("Reheat Layout") {
                appState.graphReheat = UUID()
            }
        }
    }
}
