import Foundation
import Darwin

enum ClientUpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct ClientUpdateTarget {
    let version: String
    let launcherHash: String
    let clientHash: String
}

struct ClientFileHashes {
    let launcher: String?
    let client: String?

    func matches(_ target: ClientUpdateTarget) -> Bool {
        launcher == target.launcherHash && client == target.clientHash
    }
}

// The official updater owns downloading and applying multiplayer files.
// An updater exit code alone never authorizes loading the CEF helper.
enum OfficialClientUpdater {
    static func newestVersion(in output: String) throws -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("newest release: ") }
        guard lines.count == 1,
              let version = lines[0].dropFirst("newest release: ".count).split(separator: " ").first,
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw ClientUpdateError.message("Could not read the official KCD:MP update response. Your multiplayer files have been left unchanged.")
        }
        return String(version)
    }

    static func ensure(target: ClientUpdateTarget,
                       hashes: () throws -> ClientFileHashes,
                       run: (String) throws -> String,
                       status: (String) -> Void) throws {
        if try hashes().matches(target) { return }
        status("Checking the KCD:MP multiplayer update…")
        let latest = try newestVersion(in: run("--update-check"))
        guard latest == target.version else {
            throw ClientUpdateError.message("The official updater offers KCD:MP \(latest), while this Mac app supports \(target.version). Download the matching Mac build before updating. Your multiplayer files have been left unchanged.")
        }
        status("Updating KCD:MP multiplayer to \(target.version)…")
        _ = try run("--update")
        status("Verifying the updated multiplayer files…")
        guard try hashes().matches(target) else {
            throw ClientUpdateError.message("The KCD:MP updater finished, but the launcher or client still does not match \(target.version). The game has not been started. Keep all files from the official multiplayer ZIP together.")
        }
    }
}

final class UpdateCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct OfficialUpdateProcess {
    let executable: URL
    let arguments: [String]
    let directory: URL
    let environment: [String: String]

    static func command(launcher: URL, steam: [String: String]) throws -> OfficialUpdateProcess {
        guard let prefix = steam["WINEPREFIX"], !prefix.isEmpty else {
            throw ClientUpdateError.message("Start Windows Steam in the selected bottle before updating KCD:MP.")
        }
        let executable: URL
        let arguments: [String]
        if FileManager.default.fileExists(atPath: prefix + "/cxbottle.conf") {
            guard let root = steam["CX_ROOT"], root.hasPrefix("/"),
                  let bottle = steam["CX_BOTTLE"], !bottle.isEmpty else {
                throw ClientUpdateError.message("Could not identify the running CrossOver Steam bottle.")
            }
            let drive = URL(fileURLWithPath: prefix).appendingPathComponent("drive_c").path + "/"
            guard launcher.path.hasPrefix(drive) else { throw ClientUpdateError.message("The selected launcher is outside the running Steam bottle.") }
            let windows = "C:\\" + launcher.path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
            executable = URL(fileURLWithPath: root + "/bin/wine")
            arguments = ["--bottle", bottle, "--cx-app", windows, "--"]
        } else {
            guard let wine = steam["WINE"], wine.hasPrefix("/") else {
                throw ClientUpdateError.message("Could not identify the running Steam Wine runtime.")
            }
            executable = URL(fileURLWithPath: wine)
            arguments = [launcher.path]
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ClientUpdateError.message("The running Steam Wine executable is unavailable.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(steam) { _, steamValue in steamValue }
        environment.removeValue(forKey: "WINELOADERNOEXEC")
        environment["WINEDEBUG"] = "-all"
        return OfficialUpdateProcess(executable: executable, arguments: arguments,
                                     directory: launcher.deletingLastPathComponent(), environment: environment)
    }

    func run(_ action: String, cancellation: UpdateCancellation,
             timeout: TimeInterval? = nil) throws -> String {
        guard ["--update-check", "--update"].contains(action) else { throw ClientUpdateError.message("Unsupported multiplayer update action.") }
        guard !cancellation.isCancelled else { throw ClientUpdateError.message("KCD:MP update cancelled.") }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("kcd2mp-update-" + UUID().uuidString + ".log")
        let descriptor = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ClientUpdateError.message("Could not create the multiplayer update log.") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + [action]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout ?? (action == "--update" ? 600 : 30))
        while process.isRunning && Date() < deadline && !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.05) }
        let interrupted = process.isRunning
        if interrupted {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw ClientUpdateError.message("KCD:MP update cancelled.") }
        if interrupted { throw ClientUpdateError.message("The official KCD:MP updater timed out. Try again when its download service is available.") }
        let data = try Data(contentsOf: outputURL)
        let text = String(decoding: data.suffix(1024 * 1024), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
            throw ClientUpdateError.message("The official KCD:MP updater exited with code \(process.terminationStatus).\n\(detail)")
        }
        return text
    }
}
