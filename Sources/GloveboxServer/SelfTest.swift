import CoreGraphics
import Foundation
import ImageIO
import SimBridge

/// `glovebox-mcp selftest`: the end-to-end check that glovebox works on this Mac.
/// It serves a page whose one button fills the screen, opens it in Safari,
/// and taps it through a child `glovebox-mcp serve` over real JSON-RPC, the path
/// an agent uses. It passes only if the page saw the tap (it requests
/// /tapped) and the screen turned from blue to yellow.
///
/// selftest.json holds no times or counts, so two passing runs write the same
/// bytes and a diff shows what changed.
enum SelfTest {
    struct Check: Codable {
        let name: String
        let ok: Bool
        let detail: String?
    }

    struct Result: Codable {
        let glovebox: String
        let checks: [Check]
        let ok: Bool
    }

    /// Safari drops the first touch on a page now and then, before its view
    /// takes focus, so the tap is retried.
    static let tapAttempts = 3

    static let page = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">\
        <title>glovebox selftest</title><style>html,body{margin:0;height:100%}\
        button{position:fixed;inset:0;width:100%;height:100%;border:0;background:#0000ff;color:#fff;font:bold 40px -apple-system}\
        body.tapped button{background:#ffff00;color:#000}</style></head>\
        <body><button onclick="document.body.className='tapped';fetch('/tapped')">Tap me</button></body></html>
        """

    static func run(_ arguments: [String]) async -> CLI.Exit {
        var udid: String?
        var out = NSTemporaryDirectory() + "glovebox-selftest/selftest.json"
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--udid" where index + 1 < arguments.count:
                udid = arguments[index + 1]
                index += 2
            case "--out" where index + 1 < arguments.count:
                out = arguments[index + 1]
                index += 2
            default:
                CLI.printError("selftest takes --udid UDID and --out PATH.")
                return .usage
            }
        }
        var checks: [Check] = []
        func check(_ name: String, _ ok: Bool, _ detail: String? = nil) -> Bool {
            checks.append(Check(name: name, ok: ok, detail: ok ? nil : detail))
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok || detail == nil ? "" : ": \(detail!)")")
            return ok
        }
        await body(udid: udid, check: check)
        let result = Result(glovebox: GloveboxServer.version, checks: checks, ok: checks.allSatisfy(\.ok))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (encoder.encode(result) + Data("\n".utf8)).write(to: URL(fileURLWithPath: out))
            print("Wrote \(out)")
        } catch {
            CLI.printError("Could not write \(out): \(error.localizedDescription)")
        }
        print(result.ok ? "selftest passed" : "selftest FAILED")
        return result.ok ? .success : .toolFailed
    }

    private static func body(udid: String?, check: (String, Bool, String?) -> Bool) async {
        let server: PageServer
        do {
            server = try PageServer(page: page)
        } catch {
            _ = check("serve the test page", false, SimBridgeError.message(for: error))
            return
        }
        defer { server.stop() }
        _ = check("serve the test page", true, nil)

        let client: MCPChild
        do {
            client = try MCPChild()
            _ = try client.call("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                               "clientInfo": ["name": "glovebox-selftest", "version": GloveboxServer.version]])
            client.notify("notifications/initialized")
        } catch {
            _ = check("start glovebox-mcp serve and initialize over JSON-RPC", false, SimBridgeError.message(for: error))
            return
        }
        defer { client.stop() }
        _ = check("start glovebox-mcp serve and initialize over JSON-RPC", true, nil)

        var device: [String: Any] = [:]
        if let udid { device["udid"] = udid }
        let open = client.tool("open_url", device.merging(["url": "http://127.0.0.1:\(server.port)/", "screenshot": false]) { $1 })
        guard check("open the page in Safari", open.ok, open.text) else { return }
        guard check("Safari loaded the page", server.waitFor("/", timeout: 15), "the page server got no request; is Safari on a first-run screen?") else { return }
        // Let the page paint before looking at it.
        _ = client.tool("wait_for", device.merging(["label": "Tap me", "timeout_ms": 10000, "screenshot": false]) { $1 })
        let before = client.tool("screenshot", device)
        guard check("the page shows blue", before.color.map(isBlue) ?? false, "center pixel \(before.color.map(describe) ?? "unreadable")") else { return }

        var tapped = false
        var after: ToolOutcome?
        for _ in 0..<tapAttempts where !tapped {
            let size = before.size ?? CGSize(width: 200, height: 400)
            let tap = client.tool("tap", device.merging(["x": Int(size.width / 2), "y": Int(size.height / 2)]) { $1 })
            guard tap.ok else {
                _ = check("tap the button", false, tap.text)
                return
            }
            tapped = server.waitFor("/tapped", timeout: 3)
            after = client.tool("screenshot", device)
        }
        _ = check("tap the button", true, nil)
        _ = check("the page saw the tap", tapped, "no /tapped request after \(tapAttempts) taps")
        _ = check("the page turned yellow", after?.color.map(isYellow) ?? false, "center pixel \(after?.color.map(describe) ?? "unreadable")")
    }

    typealias RGB = (r: Int, g: Int, b: Int)
    static func isBlue(_ c: RGB) -> Bool { c.b > 180 && c.r < 80 && c.g < 80 }
    static func isYellow(_ c: RGB) -> Bool { c.r > 180 && c.g > 180 && c.b < 100 }
    static func describe(_ c: RGB) -> String { "rgb(\(c.r),\(c.g),\(c.b))" }

    /// The center pixel of an encoded image.
    static func centerColor(of data: Data) -> RGB? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Draw the image so its center lands on the one-pixel context.
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    struct ToolOutcome {
        var ok = false
        var text = ""
        var color: RGB?
        var size: CGSize?
    }
}

/// A child `glovebox-mcp serve`, spoken to in newline-delimited JSON-RPC.
private final class MCPChild {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1

    init() throws {
        guard let executable = Bundle.main.executableURL else { throw SimBridgeError("Cannot find glovebox-mcp's own path.") }
        process.executableURL = executable
        process.arguments = ["serve", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func notify(_ method: String) {
        write(["jsonrpc": "2.0", "method": method])
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (message["id"] as? NSNumber)?.intValue == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw SimBridgeError("JSON-RPC error: \(error["message"] ?? "unknown")")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw SimBridgeError("glovebox-mcp serve exited.") }
            buffer.append(data)
        }
    }

    func tool(_ name: String, _ arguments: [String: Any]) -> SelfTest.ToolOutcome {
        var outcome = SelfTest.ToolOutcome()
        do {
            let result = try call("tools/call", ["name": name, "arguments": arguments])
            outcome.ok = (result["isError"] as? Bool) != true
            for item in result["content"] as? [[String: Any]] ?? [] {
                if let text = item["text"] as? String {
                    outcome.text += (outcome.text.isEmpty ? "" : " ") + text
                    if let match = text.firstMatch(of: #/Screen is (\d+)x(\d+) points/#), let w = Double(match.1), let h = Double(match.2) {
                        outcome.size = CGSize(width: w, height: h)
                    }
                }
                if let base64 = item["data"] as? String, let data = Data(base64Encoded: base64) {
                    outcome.color = SelfTest.centerColor(of: data)
                }
            }
        } catch {
            outcome.text = SimBridgeError.message(for: error)
        }
        return outcome
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        try? input.fileHandleForWriting.write(contentsOf: data)
    }
}

/// The smallest HTTP server that serves one page and records request paths.
private final class PageServer: @unchecked Sendable {
    let port: UInt16
    private let socket: Int32
    private let page: Data
    private let lock = NSLock()
    private var paths: [String] = []
    private var stopped = false

    init(page: String) throws {
        self.page = Data(page.utf8)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SimBridgeError("Could not open a socket for the test page.") }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 16) == 0 else {
            close(socket)
            throw SimBridgeError("Could not listen on 127.0.0.1 for the test page.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        lock.withLock { stopped = true }
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }

    /// Waits for a request for `path`.
    func waitFor(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ paths.contains(path) }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func serve() {
        while true {
            let client = accept(socket, nil, nil)
            guard client >= 0 else {
                if lock.withLock({ stopped }) { return }
                continue
            }
            var request = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &request, request.count)
            let line = String(decoding: request.prefix(max(0, count)), as: UTF8.self).split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            lock.withLock { paths.append(path) }
            let body = path == "/" ? page : Data("ok".utf8)
            let status = path == "/" || path == "/tapped" ? "200 OK" : "404 Not Found"
            let type = path == "/" ? "text/html; charset=utf-8" : "text/plain"
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }
}
