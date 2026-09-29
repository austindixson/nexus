import XCTest
@testable import Nexus

final class CLICredentialStoreTests: XCTestCase {
    func testParseClaudeCredentialsNested() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "tok_access",
            "refreshToken": "tok_refresh",
            "expiresAt": 9999999999999
          }
        }
        """.data(using: .utf8)!
        let session = try XCTUnwrap(CLICredentialStore.parseClaudeCredentials(data: json))
        XCTAssertEqual(session.accessToken, "tok_access")
        XCTAssertEqual(session.refreshToken, "tok_refresh")
        XCTAssertFalse(session.isExpired)
    }

    func testParseClaudeCredentialsExpired() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"x","expiresAt":1}}
        """.data(using: .utf8)!
        let session = try XCTUnwrap(CLICredentialStore.parseClaudeCredentials(data: json))
        XCTAssertTrue(session.isExpired)
    }

    func testParseCodexChatGPTOAuth() throws {
        let json = """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "at",
            "refresh_token": "rt",
            "account_id": "acct_1"
          }
        }
        """.data(using: .utf8)!
        let cred = try XCTUnwrap(CLICredentialStore.parseCodexAuth(data: json))
        guard case .chatgptOAuth(let access, let account, let refresh) = cred else {
            return XCTFail("expected chatgptOAuth")
        }
        XCTAssertEqual(access, "at")
        XCTAssertEqual(account, "acct_1")
        XCTAssertEqual(refresh, "rt")
    }

    func testParseCodexAPIKeyWins() throws {
        let json = """
        {
          "OPENAI_API_KEY": "sk-test",
          "tokens": { "access_token": "at", "account_id": "acct" }
        }
        """.data(using: .utf8)!
        let cred = try XCTUnwrap(CLICredentialStore.parseCodexAuth(data: json))
        guard case .apiKey(let key) = cred else {
            return XCTFail("expected apiKey")
        }
        XCTAssertEqual(key, "sk-test")
    }

    func testParseEnvFileDeepSeek() {
        let raw = """
        # comment
        TYPESAFE_API_KEY=ignore
        DEEPSEEK_API_KEY="ds-secret"
        OPENAI_MODEL=homebase-brain
        export OPENAI_BASE_URL=http://example:9081/v1
        """.data(using: .utf8)!
        let map = CLICredentialStore.parseEnvFile(data: raw)
        XCTAssertEqual(map["DEEPSEEK_API_KEY"], "ds-secret")
        XCTAssertEqual(map["OPENAI_BASE_URL"], "http://example:9081/v1")
        XCTAssertEqual(map["TYPESAFE_API_KEY"], "ignore")
        XCTAssertNil(map["# comment"])
    }

    func testClmEnvStatusReportsDeepSeekKeyNameOnly() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-cli-oauth-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = dir.appendingPathComponent(".env")
        try! "DEEPSEEK_API_KEY=fake-not-a-real-key\n".write(to: env, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let status = CLICredentialStore.clmEnvStatus(path: env.path)
        guard case .available(let msg) = status else {
            return XCTFail("expected available")
        }
        XCTAssertTrue(msg.contains("DEEPSEEK_API_KEY"))
        XCTAssertFalse(msg.contains("fake-not-a-real-key"))
    }
}
