import XCTest
@testable import Nexus

final class AIConfigurationTests: XCTestCase {
    func testMigrateLegacyOpenAICompatibleToOpenAI() {
        let kind = AIConfiguration.migrateProvider(
            raw: "openAICompatible",
            remoteURL: "https://api.openai.com/v1"
        )
        XCTAssertEqual(kind, .openai)
    }

    func testMigrateLegacyOpenAICompatibleToRemote() {
        let kind = AIConfiguration.migrateProvider(
            raw: "openAICompatible",
            remoteURL: "https://openrouter.ai/api/v1"
        )
        XCTAssertEqual(kind, .remoteOpenAI)
    }

    func testMigrateUnknownFallsBackToDisabled() {
        XCTAssertEqual(
            AIConfiguration.migrateProvider(raw: "not-a-provider", remoteURL: ""),
            .disabled
        )
    }

    func testNormalizeBaseURLTrimsSlashAndRequiresHTTP() {
        let url = AIConfiguration.normalizeBaseURL(" https://example.ts.net/v1/ ")
        XCTAssertEqual(url?.absoluteString, "https://example.ts.net/v1")
        XCTAssertNil(AIConfiguration.normalizeBaseURL("ftp://bad.example"))
        XCTAssertNil(AIConfiguration.normalizeBaseURL("not a url"))
        XCTAssertNotNil(AIConfiguration.normalizeBaseURL("http://100.64.0.1:11434"))
    }

    func testCodexRejectsPlatformAPIModels() {
        XCTAssertTrue(AIConfiguration.isPlatformAPIOnlyModel("gpt-4o-mini"))
        XCTAssertTrue(AIConfiguration.isPlatformAPIOnlyModel("gpt-4o"))
        XCTAssertTrue(AIConfiguration.isPlatformAPIOnlyModel("gpt-4-turbo"))
        XCTAssertFalse(AIConfiguration.isPlatformAPIOnlyModel("gpt-5.5"))
        XCTAssertFalse(AIConfiguration.isPlatformAPIOnlyModel("gpt-5.6-sol"))
        XCTAssertEqual(AIConfiguration.resolvedCodexModelID("gpt-4o-mini"), AIConfiguration.codexDefaultModel)
        XCTAssertEqual(AIConfiguration.resolvedCodexModelID("gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(AIConfiguration.resolvedCodexModelID(""), AIConfiguration.codexDefaultModel)
    }
}
