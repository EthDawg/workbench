import Foundation
import Darwin

public enum PresenterSocket {
    /// Short enough for sockaddr_un even when the user's home has a long path.
    public static func path(preview: Bool) throws -> String {
        let directory = "/tmp/workbench-browser-\(getuid())"
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw PresenterError.unsafePath }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { throw PresenterError.unsafePath }
        return directory + (preview ? "/preview.sock" : "/app.sock")
    }
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw PresenterError.unsafePath }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    public static func connect(to path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PresenterError.unavailable }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw PresenterError.unavailable }
        guard sameUser(fd) else { close(fd); throw PresenterError.unsafePath }
        configure(fd); return fd
    }
    public static func sameUser(_ fd: Int32) -> Bool {
        var user: uid_t = 0, group: gid_t = 0
        return getpeereid(fd, &user, &group) == 0 && user == getuid()
    }
    public static func configure(_ fd: Int32) {
        // macOS accepts inherit the listener's O_NONBLOCK flag. Dedicated readers
        // must block between frames instead of treating a quiet connection as EOF.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    public static func readExact(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let received: Bool = data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let amount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if amount < 0 && errno == EINTR { continue }
                if amount <= 0 { return false }; offset += amount
            }
            return true
        }
        guard received else { throw PresenterError.disconnected }; return data
    }
    public static func readMessage(_ fd: Int32) throws -> PresenterMessage {
        let count = try PresenterWire.length(readExact(fd, count: 4))
        return try PresenterWire.decode(readExact(fd, count: count))
    }
    public static func write(_ data: Data, to fd: Int32) throws {
        let written: Bool = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if amount < 0 && errno == EINTR { continue }
                if amount <= 0 { return false }; offset += amount
            }
            return true
        }
        guard written else { throw PresenterError.disconnected }
    }
}
