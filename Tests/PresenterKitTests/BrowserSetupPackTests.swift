import XCTest
@testable import PresenterKit

final class BrowserSetupPackTests: XCTestCase {
    func testCompoundRoundTripAndSharedRoles() throws {
        let pack = BrowserSetupPack.compound()
        XCTAssertEqual(try BrowserSetupPack.decode(pack.data()), pack)
        for role in pack.roles {
            let payload = try pack.payload(for: role.id)
            XCTAssertEqual(payload.bookmarks.count, pack.sharedBookmarks.count + role.bookmarks.count)
            XCTAssertEqual(Array(payload.bookmarks.prefix(3)), pack.sharedBookmarks)
            XCTAssertEqual(payload.roleID, role.id)
        }
    }
    func testRejectsUnsupportedAndDuplicateIntent() throws {
        let data = try BrowserSetupPack.compound().data()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw["passwords"] = ["untrusted"]
        XCTAssertThrowsError(try BrowserSetupPack.decode(JSONSerialization.data(withJSONObject: raw)))
        var pack = BrowserSetupPack.compound()
        pack.roles[0].bookmarks.append(pack.sharedBookmarks[0])
        XCTAssertThrowsError(try pack.validate())
        pack = .compound(); pack.roles.append(pack.roles[0])
        XCTAssertThrowsError(try pack.validate())
        pack = .compound(); pack.schema = 2
        XCTAssertThrowsError(try pack.validate())
    }
    func testURLChecksPreserveDemoRoutesButRejectSecretsAndSchemes() throws {
        let good = "https://compound-snowy-pi.vercel.app/?sector=work#overview"
        XCTAssertTrue(BrowserSetupPack.safeURL(good))
        var pack = BrowserSetupPack.compound(); pack.roles[0].launchURLs = [good]
        XCTAssertEqual(try BrowserSetupPack.decode(pack.data()).roles[0].launchURLs, [good])
        for url in ["javascript:alert(1)", "file:///tmp/demo", "chrome://settings", "https://me:secret@example.com/", "https://example.com/?ACCESS_TOKEN=x", "https://example.com/?%74oken=x", "https://example.com/#access_token=x", "https://example.com/#/route?token=x", "https://example.com/\n", "https://example.com\\evil/"] {
            XCTAssertFalse(BrowserSetupPack.safeURL(url), url)
        }
    }
    func testCapacityAndRoleIdentifiersAreBounded() throws {
        var pack = BrowserSetupPack.compound(); pack.roles[0].launchURLs = (0...8).map { "https://example.com/\($0)" }
        XCTAssertThrowsError(try pack.validate())
        pack = .compound(); pack.roles[0].launchURLs = ["https://example.com", "https://EXAMPLE.com:443/"]
        XCTAssertThrowsError(try pack.validate())
        pack = .compound(); pack.roles[0].id = "../outside"
        XCTAssertThrowsError(try pack.validate())
        pack = .compound(); pack.sharedBookmarks = (0...60).map { .init(id: "b\($0)", title: "Link", url: "https://example.com/", folder: "Shared") }
        XCTAssertThrowsError(try pack.validate())
        XCTAssertThrowsError(try BrowserSetupPack.decode(Data(repeating: 32, count: BrowserSetupPack.byteLimit + 1)))
    }
    func testHTMLExportEscapesUntrustedLabelsAndPreservesFolderOrder() throws {
        var pack = BrowserSetupPack.compound()
        pack.sharedBookmarks[0].title = "<script>&\""
        pack.sharedBookmarks[0].url = "https://example.com/?x=1&y=2"
        let html = try pack.bookmarkHTML(for: "manager")
        XCTAssertTrue(html.contains("&lt;script&gt;&amp;&quot;"))
        XCTAssertTrue(html.contains("https://example.com/?x=1&amp;y=2"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("Pocket · Ask"))
        XCTAssertTrue(html.contains("<H3>Shared</H3>"))
    }
    func testSetupWireRoundTripsWithoutMachineAssignmentsInPack() throws {
        let pack = BrowserSetupPack.compound()
        var request = PresenterMessage(type: "setupPreview"); request.setup = try pack.payload(for: "manager")
        request.expiresAt = 123
        let frame = try PresenterWire.encode(request)
        let decoded = try PresenterWire.decode(frame.dropFirst(4))
        XCTAssertEqual(decoded.setup, request.setup)
        let raw = String(decoding: try pack.data(), as: UTF8.self)
        XCTAssertFalse(raw.contains("profileID")); XCTAssertFalse(raw.contains("reviewToken"))
    }
}
