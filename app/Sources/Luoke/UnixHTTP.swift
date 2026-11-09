import Foundation

/// 很小的 HTTP/1.1 客户端，跑在 Unix socket 上（核心的界面协议、主控的 socket）。
enum UnixHTTP {
    struct Failure: Error { let reason: String }

    static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(reason: "socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw Failure(reason: "路径太长") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { close(fd); throw Failure(reason: "连不上") }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                guard n > 0 else { throw Failure(reason: "写不进去") }
                off += n
            }
        }
    }

    static func head(_ method: String, _ path: String, _ body: Data?, _ extra: [String: String]) -> Data {
        var h = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        if let b = body { h += "Content-Type: application/json\r\nContent-Length: \(b.count)\r\n" }
        var d = Data((h + "\r\n").utf8)
        if let b = body { d.append(b) }
        return d
    }

    /// 一次请求：（状态码，正文）。正文读到连接关上为止（核心和主控都答 Connection: close）。
    static func request(_ socketPath: String, _ method: String, _ path: String, body: Data? = nil,
                        headers: [String: String] = [:], timeout: TimeInterval = 330) throws -> (Int, Data) {
        let fd = try connect(socketPath, timeout: timeout)
        defer { close(fd) }
        try send(fd, head(method, path, body, headers))
        var all = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            all.append(buf, count: n)
        }
        guard let split = all.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: all[..<split.lowerBound], encoding: .utf8),
              let status = Int(head.split(separator: " ").dropFirst().first ?? "") else { throw Failure(reason: "答复不对") }
        return (status, all[split.upperBound...])
    }
}

/// 订阅核心的 `GET /feed`（SSE），一条条事件回调到主线程；断了就重连。
final class FeedStream {
    private let socketPath: String
    private let onEvent: (String, Data) -> Void
    private let onConnected: (Bool) -> Void
    private var stopped = false
    private var fd: Int32 = -1
    private let lock = NSLock()

    init(socketPath: String, onEvent: @escaping (String, Data) -> Void, onConnected: @escaping (Bool) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
        self.onConnected = onConnected
    }

    func start() {
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    func stop() {
        lock.lock(); stopped = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) }; lock.unlock()
    }

    private func loop() {
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            readOnce()
            DispatchQueue.main.async { self.onConnected(false) }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func readOnce() {
        guard let fd = try? UnixHTTP.connect(socketPath, timeout: 60) else { return }   // 核心 15 秒一次 ping
        lock.lock(); self.fd = fd; lock.unlock()
        defer { lock.lock(); close(fd); self.fd = -1; lock.unlock() }
        guard (try? UnixHTTP.send(fd, UnixHTTP.head("GET", "/feed", nil, [:]))) != nil else { return }
        var pending = Data()
        var headerDone = false
        var event = ""
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            pending.append(buf, count: n)
            if !headerDone {
                guard let r = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                pending.removeSubrange(..<r.upperBound)
                headerDone = true
                DispatchQueue.main.async { self.onConnected(true) }
            }
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(data: pending[pending.startIndex..<nl], encoding: .utf8) ?? ""
                pending.removeSubrange(pending.startIndex...nl)
                if line.hasPrefix("event: ") {
                    event = String(line.dropFirst(7))
                } else if line.hasPrefix("data: "), !event.isEmpty {
                    let data = Data(line.dropFirst(6).utf8)
                    let name = event
                    DispatchQueue.main.async { self.onEvent(name, data) }
                    event = ""
                }
            }
        }
    }
}
