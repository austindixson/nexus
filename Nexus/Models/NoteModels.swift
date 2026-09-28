import Foundation
import AppKit

// MARK: - Vault node tree

enum VaultNodeKind: String, Codable, Hashable {
    case folder
    case note
    case attachment
    case canvas
}

struct VaultNode: Identifiable, Hashable, Codable {
    let id: String          // vault-relative path
    var name: String
    var kind: VaultNodeKind
    var children: [VaultNode]
    var modified: Date?

    var path: String { id }
    var isFolder: Bool { kind == .folder }
    var isNote: Bool { kind == .note }

    var title: String {
        if kind == .note || kind == .canvas {
            return (name as NSString).deletingPathExtension
        }
        return name
    }
}

// MARK: - Note document

struct NoteDocument: Identifiable, Hashable {
    let id: String          // vault-relative path without leading slash
    var title: String
    var content: String
    var absoluteURL: URL
    var modified: Date
    var frontmatter: [String: String]
    var tags: [String]
    var outgoingLinks: [WikiLink]
    var headings: [Heading]

    var folderPath: String {
        let dir = (id as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }
}

struct WikiLink: Hashable, Codable {
    var target: String
    var alias: String?
    var isEmbed: Bool
    var range: Range<String.Index>?

    // Ranges aren't Codable; store as UTF16 offsets for index persistence.
    var location: Int?
    var length: Int?

    init(target: String, alias: String? = nil, isEmbed: Bool = false, range: Range<String.Index>? = nil) {
        self.target = target
        self.alias = alias
        self.isEmbed = isEmbed
        self.range = range
    }

    enum CodingKeys: String, CodingKey {
        case target, alias, isEmbed, location, length
    }
}

struct Heading: Hashable, Identifiable {
    var id: String { "\(level)-\(line)-\(text)" }
    var level: Int
    var text: String
    var line: Int
}

struct Backlink: Hashable, Identifiable {
    var id: String { "\(sourcePath)#\(context.hashValue)" }
    var sourcePath: String
    var sourceTitle: String
    var context: String
    var isLinked: Bool // false = unlinked mention
}

// MARK: - Graph

struct GraphNode: Identifiable, Hashable {
    let id: String
    var label: String
    var kind: GraphNodeKind
    var path: String?
    var tags: [String]
    var folder: String
    var degree: Int
    /// One-line summary from frontmatter `description` / `summary`, or first body line.
    var summary: String?
    var x: Double
    var y: Double
    var vx: Double = 0
    var vy: Double = 0
    var pinned: Bool = false
}

enum GraphNodeKind: String, Hashable {
    case note
    case tag
    case attachment
    case unresolved
}

struct GraphEdge: Identifiable, Hashable {
    let id: String
    var source: String
    var target: String
    var weight: Double
}

struct GraphSnapshot: Hashable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
}

// MARK: - Canvas

struct CanvasDocument: Codable, Hashable {
    var nodes: [CanvasCard]
    var edges: [CanvasArrow]
    var groups: [CanvasGroup]
}

struct CanvasCard: Identifiable, Codable, Hashable {
    var id: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var type: String // "text" | "file" | "link"
    var text: String?
    var file: String?
    var color: String?
}

struct CanvasArrow: Identifiable, Codable, Hashable {
    var id: String
    var from: String
    var to: String
    var label: String?
}

struct CanvasGroup: Identifiable, Codable, Hashable {
    var id: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var label: String
    var color: String?
}

// MARK: - App modes

enum MainMode: String, CaseIterable, Identifiable {
    case editor
    case graph
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Editor"
        case .graph: return "Graph"
        case .canvas: return "Canvas"
        }
    }
}

enum EditorMode: String, CaseIterable {
    case source
    case livePreview
    case split
}

enum GraphViewMode: String {
    case global
    case local
}

enum LeftSidebarTab: String, CaseIterable, Identifiable {
    case files
    case search
    case tags
    case outline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .search: return "Search"
        case .tags: return "Tags"
        case .outline: return "Outline"
        }
    }

    var systemImage: String {
        switch self {
        case .files: return "folder"
        case .search: return "magnifyingglass"
        case .tags: return "tag"
        case .outline: return "list.bullet.indent"
        }
    }
}

enum RightSidebarTab: String, CaseIterable, Identifiable {
    case backlinks
    case outgoing
    case properties
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backlinks: return "Backlinks"
        case .outgoing: return "Outgoing"
        case .properties: return "Properties"
        case .ask: return "Ask Nexus"
        }
    }

    var systemImage: String {
        switch self {
        case .backlinks: return "link"
        case .outgoing: return "arrow.up.right"
        case .properties: return "doc.text"
        case .ask: return "sparkles"
        }
    }
}
