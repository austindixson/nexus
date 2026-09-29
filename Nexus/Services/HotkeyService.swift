import Foundation
import AppKit
import SwiftUI
import Combine

/// User-customizable keyboard shortcuts. Defaults match historical Nexus bindings.
@MainActor
final class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    struct Chord: Codable, Hashable, Equatable {
        var key: String          // lowercased character or special: "return", "escape", "space"
        var command: Bool
        var shift: Bool
        var option: Bool
        var control: Bool

        var modifiers: EventModifiers {
            var m: EventModifiers = []
            if command { m.insert(.command) }
            if shift { m.insert(.shift) }
            if option { m.insert(.option) }
            if control { m.insert(.control) }
            return m
        }

        var keyEquivalent: KeyEquivalent {
            switch key {
            case "return": return .return
            case "escape": return .escape
            case "space": return .space
            case "tab": return .tab
            case "delete": return .delete
            case "up": return .upArrow
            case "down": return .downArrow
            case "left": return .leftArrow
            case "right": return .rightArrow
            default:
                if let c = key.first { return KeyEquivalent(c) }
                return KeyEquivalent("?")
            }
        }

        var display: String {
            var parts: [String] = []
            if control { parts.append("⌃") }
            if option { parts.append("⌥") }
            if shift { parts.append("⇧") }
            if command { parts.append("⌘") }
            let k: String
            switch key {
            case "return": k = "↩"
            case "escape": k = "⎋"
            case "space": k = "Space"
            case "tab": k = "⇥"
            case "delete": k = "⌫"
            case "up": k = "↑"
            case "down": k = "↓"
            case "left": k = "←"
            case "right": k = "→"
            default: k = key.uppercased()
            }
            parts.append(k)
            return parts.joined()
        }

        static func cmd(_ k: String) -> Chord {
            Chord(key: k, command: true, shift: false, option: false, control: false)
        }
        static func cmdShift(_ k: String) -> Chord {
            Chord(key: k, command: true, shift: true, option: false, control: false)
        }
        static func cmdOpt(_ k: String) -> Chord {
            Chord(key: k, command: true, shift: false, option: true, control: false)
        }
        static func cmdOptShift(_ k: String) -> Chord {
            Chord(key: k, command: true, shift: true, option: true, control: false)
        }
    }

    struct ActionDef: Identifiable, Hashable {
        let id: String
        let title: String
        let category: String
    }

    static let actions: [ActionDef] = [
        ActionDef(id: "newNote", title: "New note", category: "File"),
        ActionDef(id: "newFolder", title: "New folder", category: "File"),
        ActionDef(id: "openVault", title: "Open vault…", category: "File"),
        ActionDef(id: "dailyNote", title: "Open daily note", category: "File"),
        ActionDef(id: "importSource", title: "Import source…", category: "File"),
        ActionDef(id: "commandPalette", title: "Command palette", category: "Navigation"),
        ActionDef(id: "quickSwitcher", title: "Quick switcher", category: "Navigation"),
        ActionDef(id: "searchVault", title: "Search vault", category: "Navigation"),
        ActionDef(id: "toggleLeft", title: "Toggle left sidebar", category: "View"),
        ActionDef(id: "toggleRight", title: "Toggle right sidebar", category: "View"),
        ActionDef(id: "modeEditor", title: "Editor mode", category: "View"),
        ActionDef(id: "modeGraph", title: "Graph view", category: "View"),
        ActionDef(id: "modeLocalGraph", title: "Local graph", category: "View"),
        ActionDef(id: "modeCanvas", title: "Canvas", category: "View"),
        ActionDef(id: "askNexus", title: "Ask Nexus", category: "Nexus"),
        ActionDef(id: "rebuildIndex", title: "Rebuild vault index", category: "Nexus"),
    ]

    static let defaults: [String: Chord] = [
        "newNote": .cmd("n"),
        "newFolder": .cmdShift("n"),
        "openVault": .cmdShift("o"),
        "dailyNote": .cmd("d"),
        "importSource": .cmdShift("i"),
        "commandPalette": .cmd("p"),
        "quickSwitcher": .cmd("o"),
        "searchVault": .cmdShift("f"),
        "toggleLeft": .cmdOpt("1"),
        "toggleRight": .cmdOpt("2"),
        "modeEditor": .cmdOpt("e"),
        "modeGraph": .cmdOpt("g"),
        "modeLocalGraph": .cmdOptShift("g"),
        "modeCanvas": .cmdOpt("c"),
        "askNexus": .cmdOpt("j"),
        "rebuildIndex": Chord(key: "r", command: true, shift: true, option: true, control: false),
    ]

    @Published private(set) var chords: [String: Chord]
    private let defaultsKey = "nexus.hotkeys.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Chord].self, from: data) {
            var merged = Self.defaults
            for (k, v) in decoded { merged[k] = v }
            chords = merged
        } else {
            chords = Self.defaults
        }
    }

    func chord(for id: String) -> Chord {
        chords[id] ?? Self.defaults[id] ?? .cmd("?")
    }

    func setChord(_ chord: Chord, for id: String) {
        chords[id] = chord
        persist()
    }

    func resetAll() {
        chords = Self.defaults
        persist()
    }

    func reset(id: String) {
        if let d = Self.defaults[id] {
            chords[id] = d
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(chords) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Capture chord from an NSEvent (for recorder UI).
    static func chord(from event: NSEvent) -> Chord? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require at least one modifier for safety (except function keys — still require mod).
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let opt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        guard cmd || opt || ctrl else { return nil }

        let key: String
        switch event.keyCode {
        case 36: key = "return"
        case 53: key = "escape"
        case 49: key = "space"
        case 48: key = "tab"
        case 51: key = "delete"
        case 126: key = "up"
        case 125: key = "down"
        case 123: key = "left"
        case 124: key = "right"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let c = chars.first, c.isLetter || c.isNumber
            else { return nil }
            key = String(c)
        }
        return Chord(key: key, command: cmd, shift: shift, option: opt, control: ctrl)
    }
}
