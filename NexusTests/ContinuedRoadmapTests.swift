import XCTest
@testable import Nexus

final class CloudVaultSupportTests: XCTestCase {
    func testSkipICloudPlaceholders() {
        XCTAssertTrue(CloudVaultSupport.shouldSkipFile(name: ".Note.md.icloud"))
        XCTAssertTrue(CloudVaultSupport.shouldSkipFile(name: "foo.icloud"))
        XCTAssertTrue(CloudVaultSupport.shouldSkipFile(name: ".hidden"))
        XCTAssertFalse(CloudVaultSupport.shouldSkipFile(name: "Welcome.md"))
    }

    func testConflictCopyDetection() {
        XCTAssertTrue(CloudVaultSupport.isConflictCopy(name: "Note (Conflicted copy).md"))
        XCTAssertTrue(CloudVaultSupport.isConflictCopy(name: "Ideas 2.md"))
        XCTAssertFalse(CloudVaultSupport.isConflictCopy(name: "Welcome.md"))
    }

    func testAtomicWrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.md")
        try CloudVaultSupport.atomicWrite("# Hello\n", to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "# Hello\n")
        try CloudVaultSupport.atomicWrite("# Updated\n", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Updated\n")
    }
}

final class HotkeyServiceTests: XCTestCase {
    @MainActor
    func testDefaultsAndOverride() {
        let hk = HotkeyService.shared
        let original = hk.chord(for: "newNote")
        XCTAssertTrue(original.command)
        XCTAssertEqual(original.key, "n")

        let custom = HotkeyService.Chord(key: "k", command: true, shift: true, option: false, control: false)
        hk.setChord(custom, for: "newNote")
        XCTAssertEqual(hk.chord(for: "newNote").display, "⇧⌘K")
        hk.reset(id: "newNote")
        XCTAssertEqual(hk.chord(for: "newNote").key, "n")
    }
}

final class YouTubeImportHelpersTests: XCTestCase {
    func testVideoIDParsing() {
        XCTAssertEqual(
            SourceImporter.youtubeVideoID(from: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!),
            "dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            SourceImporter.youtubeVideoID(from: URL(string: "https://youtu.be/dQw4w9WgXcQ")!),
            "dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            SourceImporter.youtubeVideoID(from: URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")!),
            "dQw4w9WgXcQ"
        )
        XCTAssertNil(SourceImporter.youtubeVideoID(from: URL(string: "https://example.com/watch")!))
    }
}

@MainActor
final class PluginBundleTests: XCTestCase {
    func testLoadDeclarativePlugin() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-plugin-\(UUID().uuidString)", isDirectory: true)
        let pluginDir = dir.appendingPathComponent("Demo.nexusplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = """
        {
          "id": "com.demo.hello",
          "name": "Demo Hello",
          "version": "1.0.0",
          "commands": [
            { "id": "hi", "title": "Say Hi", "action": "alert", "message": "Hello" }
          ],
          "postProcessors": [
            { "pattern": "TODO", "replacement": "**TODO**", "caseInsensitive": false }
          ]
        }
        """
        try manifest.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        guard let plugin = BundleNexusPlugin(bundleURL: pluginDir) else {
            return XCTFail("failed to load plugin")
        }
        XCTAssertEqual(plugin.id, "com.demo.hello")

        let app = AppState()
        let host = PluginHost()
        host.attach(app: app)
        await host.register(plugin)
        XCTAssertTrue(host.allCommands.contains { $0.title.contains("Say Hi") })

        let processed = host.markdownProcessor("fix TODO item")
        XCTAssertTrue(processed.contains("**TODO**"))
    }
}

final class FTSQueryBuilderTests: XCTestCase {
    func testBuildFTSQuery() {
        let q = VaultIndexStore.buildFTSQuery("hello world")
        XCTAssertTrue(q.contains("hello"))
        XCTAssertTrue(q.contains("world"))
        let tagged = VaultIndexStore.buildFTSQuery("tag:guide hello")
        XCTAssertFalse(tagged.contains("tag:"))
        XCTAssertTrue(tagged.contains("hello"))
    }
}
