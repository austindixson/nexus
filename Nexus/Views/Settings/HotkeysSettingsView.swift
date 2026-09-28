import SwiftUI
import AppKit

struct HotkeysSettingsView: View {
    @ObservedObject private var hotkeys = HotkeyService.shared
    @State private var recordingID: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(.headline)
                Spacer()
                Button("Reset all") {
                    hotkeys.resetAll()
                }
            }
            .padding(12)

            Text("Click a shortcut, then press the new key combination (must include ⌘, ⌥, or ⌃).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            List {
                let grouped = Dictionary(grouping: HotkeyService.actions, by: \.category)
                ForEach(grouped.keys.sorted(), id: \.self) { category in
                    Section(category) {
                        ForEach(grouped[category] ?? []) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                Button {
                                    beginRecording(action.id)
                                } label: {
                                    Text(recordingID == action.id
                                          ? "Press keys…"
                                          : hotkeys.chord(for: action.id).display)
                                        .font(.system(.body, design: .rounded).monospaced())
                                        .frame(minWidth: 100)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            recordingID == action.id
                                                ? Color.accentColor.opacity(0.25)
                                                : Color.primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 6)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Click then press new shortcut")

                                Button("↺") {
                                    hotkeys.reset(id: action.id)
                                }
                                .buttonStyle(.borderless)
                                .help("Reset to default")
                            }
                        }
                    }
                }
            }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording(_ id: String) {
        endRecording()
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // escape cancels
                Task { @MainActor in endRecording() }
                return nil
            }
            if let chord = HotkeyService.chord(from: event) {
                Task { @MainActor in
                    hotkeys.setChord(chord, for: id)
                    endRecording()
                }
                return nil
            }
            return event
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingID = nil
    }
}
