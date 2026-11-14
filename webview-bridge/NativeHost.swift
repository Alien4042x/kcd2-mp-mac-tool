import AppKit
import WebKit
import Foundation
import CoreFoundation
import Security
import AVFoundation
import CryptoKit
import Darwin

enum BridgeError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let text) = self { return text }; return "Bridge failure" }
}

struct FrameDecoder {
    static let limit = 8 * 1024 * 1024
    private var buffer = Data()
    mutating func feed(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= Self.limit else { throw BridgeError.invalid("Invalid frame length") }
            guard buffer.count >= size + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(size)))
            buffer.removeFirst(size + 4)
        }
        return frames
    }
    func finish() throws {
        guard buffer.isEmpty else { throw BridgeError.invalid("Truncated frame") }
    }
    static func encode(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard !payload.isEmpty, payload.count <= limit else { throw BridgeError.invalid("Outgoing frame too large") }
        var size = UInt32(payload.count).bigEndian
        var output = Data(bytes: &size, count: 4)
        output.append(payload)
        return output
    }
}

func validHandshake(_ object: [String: Any], token: String) -> Bool {
    func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(UInt32.max) else { return nil }
        return number.intValue
    }
    guard object["op"] as? String == "hello", integer(object["protocol"]) == 1,
          object["token"] as? String == token, token.utf8.count == 64,
          let pid = integer(object["pid"]), pid > 0 else { return false }
    return true
}

struct BridgeConfiguration {
    let steamLauncher: URL
    let executable: URL
    let allowedRoot: URL
    let logDirectory: URL
    let allowJoin: Bool
    let closeAfter: TimeInterval?
    let prefix: URL
    let cef: GameCEFConfiguration?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var allowJoin = false
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--allow-join" { allowJoin = true; index += 1; continue }
            guard ["--steam-launcher", "--exe", "--allowed-root", "--log-directory", "--close-after", "--cef-helper", "--cef-loader", "--cef-watcher", "--cef-client-sha256"].contains(key),
                  index + 1 < arguments.count, values[key] == nil else {
                throw BridgeError.invalid("Unknown, duplicate or incomplete argument: \(key)")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let steam = values["--steam-launcher"], let exe = values["--exe"],
              let root = values["--allowed-root"], let logs = values["--log-directory"],
              let bottleRange = steam.range(of: "/drive_c/") else {
            throw BridgeError.invalid("Required: --steam-launcher PATH --exe PATH --allowed-root PATH --log-directory PATH")
        }
        steamLauncher = URL(fileURLWithPath: steam).standardizedFileURL.resolvingSymlinksInPath()
        executable = URL(fileURLWithPath: exe).standardizedFileURL.resolvingSymlinksInPath()
        allowedRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        logDirectory = URL(fileURLWithPath: logs).standardizedFileURL.resolvingSymlinksInPath()
        prefix = URL(fileURLWithPath: String(steam[..<bottleRange.lowerBound])).standardizedFileURL.resolvingSymlinksInPath()
        self.allowJoin = allowJoin
        let cefKeys = ["--cef-helper", "--cef-loader", "--cef-watcher", "--cef-client-sha256"]
        let supplied = cefKeys.filter { values[$0] != nil }
        if supplied.isEmpty { cef = nil }
        else {
            guard supplied.count == cefKeys.count, allowJoin,
                  let digest = values["--cef-client-sha256"], digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw BridgeError.invalid("CEF requires all helper paths, an exact client SHA-256 and interactive Join mode")
            }
            cef = GameCEFConfiguration(helper: URL(fileURLWithPath: values["--cef-helper"]!).resolvingSymlinksInPath(),
                                       loader: URL(fileURLWithPath: values["--cef-loader"]!).resolvingSymlinksInPath(),
                                       watcher: URL(fileURLWithPath: values["--cef-watcher"]!).resolvingSymlinksInPath(), clientHash: digest)
            for file in [cef!.helper, cef!.loader, cef!.watcher] {
                guard FileManager.default.fileExists(atPath: file.path) else { throw BridgeError.invalid("Missing CEF helper component") }
            }
        }
        if let value = values["--close-after"] {
            guard let seconds = Int(value), (10...120).contains(seconds), !allowJoin else {
                throw BridgeError.invalid("Automatic close is allowed only for a 10–120 second view-only test")
            }
            closeAfter = TimeInterval(seconds)
        } else { closeAfter = nil }
        for path in [steamLauncher, executable, allowedRoot] {
            guard FileManager.default.fileExists(atPath: path.path) else { throw BridgeError.invalid("Missing path: \(path.path)") }
        }
    }
    func windowsPath(_ path: URL) -> String {
        let base = prefix.appendingPathComponent("drive_c").path + "/"
        if path.path.hasPrefix(base) { return "C:\\" + path.path.dropFirst(base.count).replacingOccurrences(of: "/", with: "\\") }
        return "Z:" + path.path.replacingOccurrences(of: "/", with: "\\")
    }
    func localURL(_ text: String) throws -> URL {
        guard let input = URL(string: text), input.scheme?.lowercased() == "file" else {
            throw BridgeError.invalid("Only local launcher pages are allowed")
        }
        var path = input.path
        if let host = input.host, !host.isEmpty, host != "localhost" { path = "/" + host + path }
        let lower = path.lowercased()
        let local: URL
        if lower.hasPrefix("/c:/") { local = prefix.appendingPathComponent("drive_c").appendingPathComponent(String(path.dropFirst(4))) }
        else if lower.hasPrefix("/z:/") { local = URL(fileURLWithPath: "/" + path.dropFirst(4)) }
        else { throw BridgeError.invalid("Unsupported Wine file URL") }
        let canonical = local.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(allowedRoot.path + "/"),
              FileManager.default.fileExists(atPath: canonical.path) else {
            throw BridgeError.invalid("Page is missing or outside the allowed launcher folder")
        }
        return canonical
    }
}

struct GameCEFConfiguration {
    let helper: URL
    let loader: URL
    let watcher: URL
    let clientHash: String
}

func readyMarkerComplete(_ data: Data) throws -> Bool {
    let expected = Data("ready: preflight passed, no existing target process\r\n".utf8)
    if data == expected { return true }
    guard data.count < expected.count, expected.starts(with: data) else { throw BridgeError.invalid("Malformed CEF readiness marker") }
    return false
}

final class BridgeHost: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let configuration: BridgeConfiguration
    private let lock = NSLock()
    private let sendLock = NSLock()
    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var authenticated = false
    private var stopped = false
    private var token = ""
    private var child: Process?
    private var traceHandle: FileHandle?
    private var childLog: FileHandle?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var initialScripts: [Int: String] = [:]
    private var lastError: String?
    private var visible = false
    private var closing = false
    private var terminationSignals: [DispatchSourceSignal] = []
    private var wineExecutable: URL?
    private var steamForChild: [String: String] = [:]
    private var cefWatcher: Process?
    private var cefReady: URL?
    private var joinPreparing = false
    var managedPlacement: LoaderPlacement?

    init(configuration: BridgeConfiguration) { self.configuration = configuration }
    func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        try? traceHandle?.write(contentsOf: Data((message + "\n").utf8))
        try? traceHandle?.synchronize()
        print(message)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try start() }
        catch { fail("Startup failed: \(error)") }
    }
    private func start() throws {
        try FileManager.default.createDirectory(at: configuration.logDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        func createLog(_ name: String) throws -> FileHandle {
            let path = configuration.logDirectory.appendingPathComponent(name).path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw BridgeError.invalid("Refusing to overwrite a diagnostic log") }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        traceHandle = try createLog("native.log")
        childLog = try createLog("windows.log")
        let loader = configuration.executable.deletingLastPathComponent().appendingPathComponent("WebView2Loader.dll")
        guard FileManager.default.fileExists(atPath: loader.path) else { throw BridgeError.invalid("The target has no WebKit bridge loader") }
        let steam = try environmentForRunningSteam(launcherPath: configuration.steamLauncher.path)
        try verifyRunningWineServer(environment: steam)
        try verifyGameNotRunning(launcherPath: configuration.steamLauncher.path)
        guard let wine = steam["WINE"], FileManager.default.isExecutableFile(atPath: wine) else { throw BridgeError.invalid("Running Steam Wine executable is unavailable") }
        wineExecutable = URL(fileURLWithPath: wine)
        steamForChild = ProcessInfo.processInfo.environment
        steamForChild.merge(steam) { _, steamValue in steamValue }
        steamForChild.removeValue(forKey: "WINELOADERNOEXEC")
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw BridgeError.invalid("Secure session token unavailable") }
        token = random.map { String(format: "%02x", $0) }.joined()
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw BridgeError.invalid("Could not create loopback listener") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw BridgeError.invalid("Could not bind loopback listener") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }) == 0 else { throw BridgeError.invalid("Could not read loopback port") }
        let port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { self.acceptConnection() }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(steam) { _, steamValue in steamValue }
        environment.removeValue(forKey: "WINELOADERNOEXEC")
        environment["KCDMP_WEBKIT_BRIDGE_ENABLED"] = "1"
        environment["KCDMP_WEBKIT_BRIDGE_PORT"] = String(port)
        environment["KCDMP_WEBKIT_BRIDGE_TOKEN"] = token
        environment["KCDMP_WEBKIT_BRIDGE_EXPECTED_EXE"] = configuration.windowsPath(configuration.executable)
        environment["KCDMP_WEBKIT_BRIDGE_TRACE"] = configuration.windowsPath(configuration.logDirectory.appendingPathComponent("com.log"))
        if configuration.executable.lastPathComponent == "KcdMp_launcher.exe",
           let dockHelper = Bundle.main.resourceURL?.appendingPathComponent("libKcdMpDockPolicy.dylib"),
           FileManager.default.fileExists(atPath: dockHelper.path), !dockHelper.path.contains(":") {
            let previous = environment["DYLD_INSERT_LIBRARIES"].flatMap { $0.isEmpty ? nil : $0 }
            environment["DYLD_INSERT_LIBRARIES"] = dockHelper.path + (previous.map { ":" + $0 } ?? "")
            environment["KCDMP_DOCK_EXPECTED_EXE"] = configuration.executable.path
            environment["KCDMP_DOCK_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment["KCDMP_DOCK_LOG"] = configuration.logDirectory.appendingPathComponent("dock-policy.log").path
            log("Enabled launcher-only native Dock policy helper")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: wine)
        process.currentDirectoryURL = configuration.executable.deletingLastPathComponent()
        process.arguments = [configuration.executable.path]
        process.environment = environment
        process.standardOutput = childLog
        process.standardError = childLog
        process.terminationHandler = { process in DispatchQueue.main.async {
            self.log("Windows target exited: \(process.terminationStatus)")
            self.finish(status: (process.terminationStatus == 0 || self.closing) && self.lastError == nil ? 0 : 1)
        } }
        child = process
        try process.run()
        log("Started exact Windows target, host PID \(process.processIdentifier), view-only=\(!configuration.allowJoin)")
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { self.requestClose() }
            source.resume()
            terminationSignals.append(source)
        }
        if let seconds = configuration.closeAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.requestClose() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            self.lock.lock(); let ready = self.authenticated; let ended = self.stopped; self.lock.unlock()
            if !ready && !ended { self.fail("No authenticated bridge connection within 20 seconds") }
        }
    }
    private func acceptConnection() {
        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else { DispatchQueue.main.async { self.fail("Bridge accept failed") }; return }
        var noSignal: Int32 = 1
        setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(accepted, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        lock.lock(); peer = accepted; lock.unlock()
        do {
            var decoder = FrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 65536)
            var isAuthenticated = false
            while true {
                let count = recv(accepted, &buffer, buffer.count, 0)
                if count == 0 { try decoder.finish(); break }
                if count < 0 { if errno == EINTR { continue }; throw BridgeError.invalid("Bridge socket read failed") }
                for data in try decoder.feed(Data(buffer.prefix(count))) {
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let op = object["op"] as? String else {
                        throw BridgeError.invalid("Invalid bridge JSON object")
                    }
                    if !isAuthenticated {
                        guard validHandshake(object, token: token) else {
                            throw BridgeError.invalid("Bridge authentication rejected")
                        }
                        isAuthenticated = true
                        lock.lock(); authenticated = true; lock.unlock()
                        timeout = timeval(tv_sec: 0, tv_usec: 0)
                        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                        send(["op": "accepted", "protocol": 1])
                        log("Authenticated protocol 1")
                        DispatchQueue.main.async { self.createWindow() }
                    } else {
                        guard op != "hello" else { throw BridgeError.invalid("Repeated handshake") }
                        DispatchQueue.main.async { self.handle(object) }
                    }
                }
            }
            log("Bridge connection closed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.lock.lock(); let ended = self.stopped; self.lock.unlock()
                if !ended && !self.closing && self.child?.isRunning == true { self.fail("Bridge disconnected while target was still running") }
            }
        } catch { DispatchQueue.main.async { self.fail("Transport failed: \(error)") } }
    }
    private func send(_ object: [String: Any]) {
        do {
            let data = try FrameDecoder.encode(object)
            sendLock.lock(); defer { sendLock.unlock() }
            lock.lock(); let socket = peer; let ended = stopped; lock.unlock()
            guard socket >= 0, !ended else { return }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.send(socket, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw BridgeError.invalid("Bridge socket write failed") }
                    offset += written
                }
            }
        } catch { DispatchQueue.main.async { self.fail("Transport send failed: \(error)") } }
    }
    private var bootstrap: String { """
    (() => {
      const events = new EventTarget();
      window.chrome = window.chrome || {};
      window.chrome.webview = {
        postMessage: message => window.webkit.messageHandlers.bridge.postMessage({op:'message',data:message}),
        addEventListener: (...args) => events.addEventListener(...args),
        removeEventListener: (...args) => events.removeEventListener(...args)
      };
      window.__kcdmpReceiveMessage = value => events.dispatchEvent(new MessageEvent('message',{data:value}));
    })();
    """ }
    private func createWindow() {
        guard window == nil else { return }
        let controller = WKUserContentController()
        controller.add(self, name: "bridge")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720), configuration: config)
        view.navigationDelegate = self
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "KCD2MP Mac"
        window.contentView = view
        window.delegate = self
        window.center()
        self.window = window; webView = view
        updateScripts()
        if visible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    private func updateScripts() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for id in initialScripts.keys.sorted() {
            controller.addUserScript(WKUserScript(source: initialScripts[id]!, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }
    private func handle(_ object: [String: Any]) {
        guard let op = object["op"] as? String else { fail("Missing operation"); return }
        createWindow()
        do {
            switch op {
            case "init":
                guard let id = object["id"] as? Int, let script = object["script"] as? String else { throw BridgeError.invalid("Malformed init") }
                initialScripts[id] = script; updateScripts()
            case "remove_init":
                guard let text = object["id"] as? String, let id = Int(text) else { throw BridgeError.invalid("Malformed remove_init") }
                initialScripts.removeValue(forKey: id); updateScripts()
            case "navigate":
                guard let text = object["url"] as? String else { throw BridgeError.invalid("Malformed navigate") }
                let url = try configuration.localURL(text)
                log("Loading original local page: \(url.lastPathComponent)")
                webView?.loadFileURL(url, allowingReadAccessTo: configuration.allowedRoot)
            case "html":
                guard let html = object["html"] as? String else { throw BridgeError.invalid("Malformed html") }
                webView?.loadHTMLString(html, baseURL: nil)
            case "eval":
                guard let id = object["id"] as? Int, let script = object["script"] as? String else { throw BridgeError.invalid("Malformed eval") }
                webView?.evaluateJavaScript(script) { value, error in
                    let result = (try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                    self.send(["op": "evaluated", "id": id, "ok": error == nil, "result": result])
                    if error != nil { self.log("JavaScript evaluation failed") }
                }
            case "visible":
                guard let value = object["value"] as? Bool else { throw BridgeError.invalid("Malformed visibility") }
                visible = value
                if value { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                else { window?.orderOut(nil) }
            case "bounds":
                guard let width = object["width"] as? Int, let height = object["height"] as? Int else { throw BridgeError.invalid("Malformed bounds") }
                if width >= 320 && height >= 240 { window?.setContentSize(NSSize(width: min(width, 1800), height: min(height, 1100))) }
            case "focus": window?.makeKeyAndOrderFront(nil); if let view = webView { window?.makeFirstResponder(view) }
            case "closed": closing = true; window?.orderOut(nil)
            default: throw BridgeError.invalid("Unsupported operation: \(op)")
            }
        } catch { fail("Request failed: \(error)") }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              body["op"] as? String == "message", let data = body["data"] as? String else {
            fail("Invalid JavaScript bridge message"); return
        }
        if let bytes = data.data(using: .utf8),
           let rpc = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           rpc["method"] as? String == "KcdMp_connect" {
            guard configuration.allowJoin else {
                log("Join blocked by explicit view-only test mode")
                rejectRPC(rpc, message: "Join is disabled for this display test")
                return
            }
            guard !joinPreparing else { rejectRPC(rpc, message: "A connection is already being prepared"); return }
            do { try verifyGameNotRunning(launcherPath: configuration.steamLauncher.path) }
            catch { rejectRPC(rpc, message: error.localizedDescription); return }
            joinPreparing = true
            let proceed = {
                self.prepareCEF { result in
                    self.joinPreparing = false
                    switch result {
                    case .success: self.send(["op": "message", "data": data])
                    case .failure(let error): self.log("CEF preflight failed: \(error)"); self.rejectRPC(rpc, message: error.localizedDescription)
                    }
                }
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async {
                    self.log(granted ? "Microphone access allowed" : "Microphone access declined")
                    proceed()
                } }
            } else { proceed() }
            return
        }
        send(["op": "message", "data": data])
    }
    private func rejectRPC(_ rpc: [String: Any], message: String) {
        guard let id = rpc["id"] as? String,
              let encoded = try? JSONSerialization.data(withJSONObject: [id, message]),
              let array = String(data: encoded, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("(()=>{const a=\(array);window.__webview__.onReply(a[0],1,JSON.stringify(a[1]));})()", completionHandler: nil)
    }
    private func readCEFReady(_ path: URL) throws -> Bool {
        do { return try readyMarkerComplete(Data(contentsOf: path)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return false }
    }
    private func prepareCEF(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let cef = configuration.cef else { completion(.success(())); return }
        do {
            let client = configuration.steamLauncher.deletingLastPathComponent().appendingPathComponent("KcdMp_client.dll")
            let actual = SHA256.hash(data: try Data(contentsOf: client)).map { String(format: "%02x", $0) }.joined()
            guard actual == cef.clientHash else { throw BridgeError.invalid("The game client changed. Refusing a mismatched CEF helper.") }
            if let existing = cefWatcher, existing.isRunning, let ready = cefReady, try readCEFReady(ready) {
                completion(.success(())); return
            }
            guard let wine = wineExecutable else { throw BridgeError.invalid("Steam runtime is unavailable") }
            let id = UUID().uuidString
            let ready = configuration.logDirectory.appendingPathComponent("cef-\(id).ready")
            let logURL = configuration.logDirectory.appendingPathComponent("cef-\(id).log")
            let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw BridgeError.invalid("Could not create CEF session log") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let watch = Process()
            watch.executableURL = wine
            let game = configuration.steamLauncher.deletingLastPathComponent().appendingPathComponent("KingdomCome.exe")
            watch.arguments = [cef.watcher.path, "--image", configuration.windowsPath(game), "--dll", configuration.windowsPath(cef.helper),
                               "--loader", configuration.windowsPath(cef.loader), "--ready-file", configuration.windowsPath(ready)]
            watch.environment = steamForChild
            watch.standardOutput = handle; watch.standardError = handle
            watch.terminationHandler = { [weak self] process in DispatchQueue.main.async {
                self?.log(process.terminationStatus == 0 ? "CEF helper initialization completed" : "CEF watcher exited: \(process.terminationStatus)")
            } }
            try watch.run()
            cefWatcher = watch; cefReady = ready
            let deadline = Date().addingTimeInterval(15)
            func waitForReadiness() {
                do {
                    guard watch.isRunning else { throw BridgeError.invalid("CEF watcher refused startup. See its session log.") }
                    if try self.readCEFReady(ready) { self.log("CEF watcher ready before official Join");completion(.success(()));return }
                    guard Date() < deadline else { watch.terminate();throw BridgeError.invalid("CEF watcher readiness timed out") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForReadiness)
                } catch { completion(.failure(error)) }
            }
            waitForReadiness()
        } catch { completion(.failure(error)) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("WebKit navigation finished")
        send(["op": "navigated", "ok": true])
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("WebKit navigation failed: \(error.localizedDescription)"); send(["op": "navigated", "ok": false])
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if url.isFileURL && path.hasPrefix(configuration.allowedRoot.path + "/") { decisionHandler(.allow) }
        else { log("Navigation outside original local UI blocked"); decisionHandler(.cancel) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("The native WebKit content process terminated") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestClose()
        return .terminateCancel
    }
    private func requestClose() {
        guard !closing else { return }
        closing = true
        log("Native close requested")
        send(["op": "close"])
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if let child = self.child, child.isRunning {
                self.log("Closing only the Windows launcher after the close grace period")
                child.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    private func fail(_ message: String) {
        if lastError == nil {
            lastError = message; log(message)
            if managedPlacement != nil && !closing {
                let alert = NSAlert()
                alert.messageText = "KCD2MP Mac"
                alert.informativeText = message + "\n\nLog: " + configuration.logDirectory.path
                alert.runModal()
            }
        }
        if let child = child, child.isRunning {
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if child.isRunning {
                    self.log("Stopping only the unresponsive target host PID")
                    Darwin.kill(child.processIdentifier, SIGKILL)
                }
            }
        }
        else { finish(status: 1) }
    }
    func applicationLoopReturned() {
        if child?.isRunning == true { child?.terminate() }
        finish(status: 1)
    }
    private func finish(status: Int32) {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let listener = self.listener; self.listener = -1
        let peer = self.peer; self.peer = -1
        lock.unlock()
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
        if peer >= 0 { shutdown(peer, SHUT_RDWR); close(peer) }
        if let watcher = cefWatcher, watcher.isRunning {
            watcher.terminate()
            let deadline = Date().addingTimeInterval(2)
            while watcher.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if watcher.isRunning { Darwin.kill(watcher.processIdentifier, SIGKILL) }
            watcher.waitUntilExit()
        }
        if let ready = cefReady { try? FileManager.default.removeItem(at: ready) }
        var finalStatus = status
        if let placement = managedPlacement {
            do { try placement.cleanup(); log("Temporary WebKit bridge removed") }
            catch { log("WebKit bridge cleanup failed: \(error.localizedDescription)"); finalStatus = 1 }
            managedPlacement = nil
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        log("Native helper stopped: \(finalStatus)")
        try? traceHandle?.close(); try? childLog?.close()
        exit(finalStatus)
    }
}

@main
struct NativeBridgeMain {
    static func main() {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
                let sample = try FrameDecoder.encode(["op": "test", "value": "čeština \" ☃"])
                var decoder = FrameDecoder(); var frames: [Data] = []
                for byte in sample { frames += try decoder.feed(Data([byte])) }
                try decoder.finish()
                guard frames.count == 1 else { throw BridgeError.invalid("Fragmented frame failed") }
                let decoded = try JSONSerialization.jsonObject(with: frames[0]) as? [String: String]
                guard decoded?["value"] == "čeština \" ☃" else { throw BridgeError.invalid("Unicode frame failed") }
                for invalid in [Data([0,0,0,0]), Data([0,128,0,1])] {
                    var bad = FrameDecoder()
                    do { _ = try bad.feed(invalid); throw BridgeError.invalid("Invalid length accepted") }
                    catch BridgeError.invalid(let reason) where reason == "Invalid frame length" { }
                }
                var truncated = FrameDecoder(); _ = try truncated.feed(Data(sample.dropLast()))
                do { try truncated.finish(); throw BridgeError.invalid("Truncation accepted") }
                catch BridgeError.invalid(let reason) where reason == "Truncated frame" { }
                let readyText = Data("ready: preflight passed, no existing target process\r\n".utf8)
                guard try readyMarkerComplete(readyText), try !readyMarkerComplete(Data()), try !readyMarkerComplete(Data(readyText.prefix(8))) else { throw BridgeError.invalid("CEF readiness parser failed") }
                do { _ = try readyMarkerComplete(Data("unexpected".utf8));throw BridgeError.invalid("Malformed readiness accepted") }
                catch BridgeError.invalid(let reason) where reason == "Malformed CEF readiness marker" { }
                let token = String(repeating: "a", count: 64)
                let hello: [String: Any] = ["op": "hello", "protocol": 1, "token": token, "pid": 42]
                guard validHandshake(hello, token: token) else { throw BridgeError.invalid("Valid handshake rejected") }
                for invalid: [String: Any] in [[:], ["op":"hello", "protocol":1, "token":token], ["op":"hello","protocol":1,"token":token,"pid":0], ["op":"hello","protocol":2,"token":token,"pid":1], ["op":"hello","protocol":1,"token":"wrong","pid":1], ["op":"hello","protocol":NSNull(),"token":token,"pid":1], ["op":"hello","protocol":true,"token":token,"pid":true]] {
                    guard !validHandshake(invalid, token: token) else { throw BridgeError.invalid("Invalid handshake accepted") }
                }
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kcdmp-webkit-selftest-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let steam = scratch.appendingPathComponent("bottle/drive_c/game/KcdMp_launcher.exe")
                let root = steam.deletingLastPathComponent().appendingPathComponent("ui")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data().write(to: steam)
                try Data().write(to: root.appendingPathComponent("launcher.html"))
                try Data().write(to: root.appendingPathComponent("s češtinou.html"))
                let config = try BridgeConfiguration(arguments: ["selftest","--steam-launcher",steam.path,"--exe",steam.path,"--allowed-root",root.path,"--log-directory",scratch.appendingPathComponent("logs").path])
                guard try config.localURL("file:///C:/game/ui/launcher.html") == root.appendingPathComponent("launcher.html"),
                      config.windowsPath(steam) == "C:\\game\\KcdMp_launcher.exe" else { throw BridgeError.invalid("Wine path mapping failed") }
                guard try config.localURL("file:///C:/game/ui/s%20%C4%8De%C5%A1tinou.html") == root.appendingPathComponent("s češtinou.html") else {
                    throw BridgeError.invalid("Escaped Unicode file URL mapping failed")
                }
                for invalid in ["https://example.com/", "file:///C:/game/ui/../KcdMp_launcher.exe", "file:///C:/game/ui/missing.html"] {
                    do { _ = try config.localURL(invalid); throw BridgeError.invalid("Invalid page accepted") }
                    catch BridgeError.invalid(let reason) where reason != "Invalid page accepted" { }
                }
                print("Self-tests passed: partial/Unicode frames, malformed lengths/EOF, session authentication and restricted Wine paths")
                return
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            if CommandLine.arguments.count == 1 {
                let delegate = PackagedAppDelegate()
                app.delegate = delegate
                withExtendedLifetime(delegate) { app.run() }
                return
            }
            let config = try BridgeConfiguration(arguments: CommandLine.arguments)
            let host = BridgeHost(configuration: config)
            app.delegate = host
            withExtendedLifetime(host) { app.run(); host.applicationLoopReturned() }
        } catch {
            fputs("\(error)\n", stderr)
            exit(2)
        }
    }
}
