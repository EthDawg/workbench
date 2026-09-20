import XCTest
import Foundation
import Darwin
@testable import PresenterKit

final class PresenterKitTests: XCTestCase {
    func testNavigationAddressesExcludeCredentialsAndEphemeralParts() {
        XCTAssertEqual(PresenterURL.canonical("https://TENANT.example:443/path?q=secret#fragment"), "https://tenant.example/path")
        XCTAssertEqual(PresenterURL.canonical("http://localhost:8080"), "http://localhost:8080/")
        for value in ["javascript:alert(1)", "file:///tmp/demo", "chrome://settings", "https://u:p@example.com/", "https://example.com\\@evil.test/", "https://example.com/\n", "relative/path", "https:///", "https://example.com:99999/"] {
            XCTAssertNil(PresenterURL.canonical(value), value)
        }
        XCTAssertNotEqual(PresenterURL.canonical("https://tenant-a.example/demo"), PresenterURL.canonical("https://tenant-b.example/demo"))
    }
    func testNamesAreBoundedAndControlFree() {
        XCTAssertTrue(PresenterURL.validName("Manager · Sydney"))
        for value in ["", "  ", "Manager\nAdmin", String(repeating: "x", count: 81)] { XCTAssertFalse(PresenterURL.validName(value)) }
    }
    func testFramingIsByteAccurateAndRoundTripsUnicode() throws {
        var message = PresenterMessage(type: "save"); message.title = "管理者 · Manager"; message.url = "https://example.com/"
        let frame = try PresenterWire.encode(message)
        XCTAssertEqual(try PresenterWire.length(frame.prefix(4)), frame.count - 4)
        let result = try PresenterWire.decode(frame.dropFirst(4))
        XCTAssertEqual(result.title, message.title); XCTAssertEqual(result.id, message.id)
    }
    func testBrowserWireIdentityMatchesJavaScriptUUIDs() throws {
        let id = UUID(uuidString: "ABCDEF12-ABCD-4BCD-ABCD-ABCDEF123456")!
        var message = PresenterMessage(id: id, type: "list")
        message.destinations = [PresenterDestination(id: id, title: "Manager", profileName: "Demo", profileID: id, url: "https://example.com/", connected: true)]
        let frame = try PresenterWire.encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.dropFirst(4)) as? [String: Any])
        let destination = try XCTUnwrap((json["destinations"] as? [[String: Any]])?.first)
        XCTAssertEqual(json["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(destination["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(destination["profileID"] as? String, id.uuidString.lowercased())
    }
    func testProtocolRejectsFutureAndOversizeMessages() throws {
        var future = PresenterMessage(type: "hello"); future.v = 2
        XCTAssertThrowsError(try PresenterWire.decode(JSONEncoder().encode(future)))
        XCTAssertThrowsError(try PresenterWire.decode(Data(repeating: 32, count: PresenterWire.limit + 1)))
        XCTAssertThrowsError(try PresenterWire.length(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try PresenterWire.length(Data([1, 0, 1, 0])))
        XCTAssertThrowsError(try PresenterWire.length(Data([1, 0])))
    }
    func testFragmentedSocketReadAndSameUser() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let message = PresenterMessage(type: "list"), frame = try PresenterWire.encode(message)
        let sender = sockets[0]
        DispatchQueue.global().async {
            for byte in frame { try? PresenterSocket.write(Data([byte]), to: sender) }
        }
        XCTAssertEqual(try PresenterSocket.readMessage(sockets[1]).id, message.id)
    }
    func testEOFDoesNotDecodePartialMessage() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        try PresenterSocket.write(Data([8, 0, 0, 0, 123]), to: sockets[0]); shutdown(sockets[0], SHUT_WR)
        XCTAssertThrowsError(try PresenterSocket.readMessage(sockets[1]))
    }
    func testSocketPathIsPrivateAndBounded() throws {
        let path = try PresenterSocket.path(preview: true)
        XCTAssertLessThan(path.utf8.count, 104)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var info = stat(); XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_uid, getuid()); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertThrowsError(try PresenterSocket.address(String(repeating: "x", count: 200)))
    }
}
