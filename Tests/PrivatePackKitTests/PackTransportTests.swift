import XCTest
@testable import PrivatePackKit

private actor HTTPFixture: PackHTTPClient {
    var replies: [PackHTTPResponse]
    var requests: [PackHTTPRequest] = []
    init(_ replies: [PackHTTPResponse]) { self.replies = replies }
    func send(_ request: PackHTTPRequest) async throws -> PackHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw PackError.transport("Unexpected request") }
        return replies.removeFirst()
    }
}
final class PackTransportTests: XCTestCase {
    func json(_ text: String, status: Int = 200) -> PackHTTPResponse { PackHTTPResponse(status: status, body: Data(text.utf8)) }
    func testDeviceFlowHasNoBroadScopesAndRefreshNeedsNoSecret() async throws {
        let http = HTTPFixture([
            json(#"{"device_code":"fixture-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            json(#"{"access_token":"fixture-access","refresh_token":"fixture-rotated-refresh","token_type":"bearer","expires_in":28800,"refresh_token_expires_in":15552000}"#)
        ])
        let auth = try GitHubPackAuthorization(clientID: "Iv1.fixture", client: http)
        let challenge = try await auth.begin()
        XCTAssertEqual(challenge.userCode, "ABCD-EFGH")
        let token = try await auth.refresh("fixture-refresh")
        XCTAssertEqual(token.refreshToken, "fixture-rotated-refresh")
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.host), ["github.com", "github.com"])
        XCTAssertNil(requests[0].form?["scope"])
        XCTAssertNil(requests[1].form?["client_secret"])
        XCTAssertEqual(requests[1].form?["grant_type"], "refresh_token")
    }
    func testUntrustedDeviceVerificationURLRejected() async throws {
        let http = HTTPFixture([json(#"{"device_code":"fixture-device","user_code":"ABCD-EFGH","verification_uri":"https://example.com/device","expires_in":900,"interval":5}"#)])
        do { _ = try await GitHubPackAuthorization(clientID: "Iv1.fixture", client: http).begin(); XCTFail("untrusted login URL accepted") }
        catch { XCTAssertTrue(error is PackError) }
    }
    func testGitHubFilesPinnedToResolvedCommitAndHashChecked() async throws {
        let sha = String(repeating: "a", count: 40)
        let body = Data("# Skill".utf8)
        let http = HTTPFixture([json(sha), PackHTTPResponse(status: 200, body: body)])
        let client = try GitHubPackClient(source: .parse("company/pack"), client: http, token: "fixture-token")
        let revision = try await client.currentRevision()
        let file = PackFile(path: "skills/test/SKILL.md", sha256: PackDigest.hex(body), size: body.count)
        let release = PackRelease(version: PackVersion("1.0.0")!, minimumAppVersion: PackVersion("2.2.0")!, manifestPath: "releases/1.0.0/pack.json", sha256: String(repeating: "b", count: 64))
        let downloaded = try await client.file(file, for: release, at: revision)
        XCTAssertEqual(downloaded, body)
        let requests = await http.requests
        XCTAssertEqual(requests[1].url.query, "ref=" + sha)
        XCTAssertEqual(requests[1].url.path, "/repos/company/pack/contents/releases/1.0.0/skills/test/SKILL.md")
        XCTAssertEqual(requests[1].authorization, "fixture-token")
        XCTAssertEqual(requests[1].limit, body.count)
    }
    func testRequestRejectsTokenRedirectAndHeaderConfusion() throws {
        for url in ["http://api.github.com/user", "https://api.github.com.evil.test/user", "https://api.github.com:443/user", "https://person@api.github.com/user", "https://api.github.com/user#fragment"] {
            XCTAssertThrowsError(try PackHTTPRequest(url: URL(string: url)!, host: "api.github.com", accept: "application/json", authorization: "fixture", limit: 100))
        }
        XCTAssertThrowsError(try PackHTTPRequest(url: URL(string: "https://api.github.com/user")!, host: "api.github.com", accept: "application/json", authorization: "secret\r\nHeader:bad", limit: 100))
    }
    func testRateLimitAndDeniedAccessHaveSafeErrors() async throws {
        for status in [401,403,404,429,500] {
            let http = HTTPFixture([json(#"{"private_secret":"must never be echoed"}"#, status: status)])
            let client = try GitHubPackClient(source: .parse("company/pack"), client: http, token: "fixture-token")
            do { _ = try await client.currentRevision(); XCTFail("HTTP error accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private_secret")); XCTAssertFalse(error.localizedDescription.contains("fixture-token")) }
        }
    }
}
