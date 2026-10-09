import Foundation
import CryptoKit
import Darwin

enum CEFLaunchError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

struct CEFLaunchPlan {
    let launcher: URL
    let gameDirectory: URL
    let prefix: URL
    let preferences: URL
    let wine: URL
    let environment: [String: String]
    let compatDLL: URL
    let loader: URL
    let watcher: URL

    func windowsPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let drive = prefix.appendingPathComponent("drive_c").path + "/"
        if path.hasPrefix(drive) {
            return "C:\\" + path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }
}

enum CEFLauncher {
    static let supportedVersion = "0.40.0"
    static let supportedClientHash = "a6ac0a5309abdf21aba9522f11252690c5092c0d5cc34b3229524c8d99a4f82b"
    private static let expectedLauncherSuffix = "program files (x86)/steam/steamapps/common/kingdomcomedeliverance2/bin/win64mastermastersteampgo/kcdmp_launcher.exe"

    private static func selectedClient(launcherPath: String) throws -> (launcher: URL, client: URL, prefix: URL) {
        let launcher = URL(fileURLWithPath: launcherPath).standardizedFileURL.resolvingSymlinksInPath()
        guard launcher.lastPathComponent == "KcdMp_launcher.exe",
              let bottleRange = launcher.path.range(of: "/drive_c/"),
              String(launcher.path[bottleRange.upperBound...]).lowercased() == expectedLauncherSuffix else {
            throw CEFLaunchError.message("Select KcdMp_launcher.exe in the Steam installation of KCD2.")
        }
        let gameDirectory = launcher.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: launcher.path),
              FileManager.default.fileExists(atPath: gameDirectory.appendingPathComponent("KingdomCome.exe").path) else {
            throw CEFLaunchError.message("The selected KCD:MP or KCD2 game executable is missing.")
        }
        let client = gameDirectory.appendingPathComponent("KcdMp_client.dll")
        guard FileManager.default.fileExists(atPath: client.path) else {
            throw CEFLaunchError.message("KcdMp_client.dll is missing next to the selected MP launcher.")
        }
        let prefix = URL(fileURLWithPath: String(launcher.path[..<bottleRange.lowerBound]))
        return (launcher, client, prefix)
    }

    private static func clientHash(_ client: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: client)).map { String(format: "%02x", $0) }.joined()
    }

    private static func officialUpdate(_ action: String, launcher: URL,
                                       steamEnvironment: [String: String]) throws -> String {
        let wine = URL(fileURLWithPath: steamEnvironment["WINE"] ?? "")
        guard wine.lastPathComponent == "wine", FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw CEFLaunchError.message("Start Windows Steam in this WineForge bottle before connecting.")
        }
        let process = Process()
        process.executableURL = wine
        process.arguments = [launcher.path, action]
        process.currentDirectoryURL = launcher.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment.merge(steamEnvironment) { _, steamValue in steamValue }
        environment.removeValue(forKey: "WINELOADERNOEXEC")
        process.environment = environment
        let outputURL = URL(fileURLWithPath: "/private/tmp/kcdmp-updater-\(UUID().uuidString).log")
        let descriptor = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CEFLaunchError.message("Could not create the KCD:MP updater log.") }
        let outputFile = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? outputFile.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputFile
        process.standardError = outputFile
        try process.run()
        let deadline = Date().addingTimeInterval(action == "--update" ? 600 : 20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw CEFLaunchError.message("KCD:MP update \(action == "--update" ? "download" : "check") timed out.")
        }
        process.waitUntilExit()
        let output = (try? Data(contentsOf: outputURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard process.terminationStatus == 0 else {
            throw CEFLaunchError.message("KCD:MP updater exited with code \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    private static func prepareClient(launcherPath: String,
                                      steamEnvironment: [String: String],
                                      serverVersion: String?,
                                      status: (String) -> Void) throws -> (version: String, cefSupported: Bool) {
        let selected = try selectedClient(launcherPath: launcherPath)
        status("Checking KCD:MP updates…")
        let check = try officialUpdate("--update-check", launcher: selected.launcher,
                                       steamEnvironment: steamEnvironment)
        guard let versionLine = check.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("newest release: ") }),
              let latest = versionLine.dropFirst("newest release: ".count).split(separator: " ").first,
              latest.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw CEFLaunchError.message("Could not read the KCD:MP updater's version response.")
        }
        let version = String(latest)
        let installedHash = try clientHash(selected.client)
        if let serverVersion,
           serverVersion.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
           serverVersion.split(separator: ".").prefix(2) != version.split(separator: ".").prefix(2) {
            status("Server uses KCD:MP \(serverVersion). Keeping the installed client for this connection…")
            return (serverVersion, installedHash == supportedClientHash &&
                    serverVersion.split(separator: ".").prefix(2) == supportedVersion.split(separator: ".").prefix(2))
        }
        if version != supportedVersion || installedHash != supportedClientHash {
            status("Updating KCD:MP to \(version)…")
            _ = try officialUpdate("--update", launcher: selected.launcher,
                                   steamEnvironment: steamEnvironment)
        }
        let updatedHash = try clientHash(selected.client)
        return (version, version == supportedVersion && updatedHash == supportedClientHash)
    }

    private static func launchLog(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func crashedGame(_ log: String) -> Bool {
        log.contains("the client crashed:") || log.contains("crash: dump written")
    }

    private static func clientReportedCrash(launcherPath: String, since start: Date) -> Bool {
        guard let bottleRange = launcherPath.range(of: "/drive_c/") else { return false }
        let users = URL(fileURLWithPath: String(launcherPath[..<bottleRange.lowerBound]))
            .appendingPathComponent("drive_c/users")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: users,
                                                                          includingPropertiesForKeys: nil) else {
            return false
        }
        for user in entries {
            let logURL = user.appendingPathComponent("AppData/Local/KcdMp/client.log")
            guard let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified >= start.addingTimeInterval(-2),
                  let log = try? String(contentsOf: logURL, encoding: .utf8) else { continue }
            if log.contains("crash report written:") && log.contains("EXCEPTION access violation") {
                return true
            }
        }
        return false
    }

    private static func crashedDuringLaunch(_ log: String, launcherPath: String,
                                            since start: Date) -> Bool {
        crashedGame(log) ||
            (log.contains("wine: Unhandled page fault on execute access") &&
             clientReportedCrash(launcherPath: launcherPath, since: start))
    }

    private static func ownedSessionProcesses(_ observed: Set<Int32>, launcherPath: String) -> Set<Int32> {
        ((try? sessionProcessIDs(launcherPath: launcherPath)) ?? []).intersection(observed)
    }

    private static func closeCrashedGame(_ observed: Set<Int32>, launcherPath: String,
                                         status: (String) -> Void) {
        let remaining = ownedSessionProcesses(observed, launcherPath: launcherPath)
        guard !remaining.isEmpty else { return }
        status("The game crashed. Closing its remaining game and debugger processes…")
        for pid in remaining { _ = Darwin.kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while !ownedSessionProcesses(observed, launcherPath: launcherPath).isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in ownedSessionProcesses(observed, launcherPath: launcherPath) {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    static func supervise(_ process: Process, launcherPath: String, logURL: URL,
                          status: (String) -> Void) throws {
        var observed = Set<Int32>()
        let start = Date()
        while process.isRunning {
            if let current = try? sessionProcessIDs(launcherPath: launcherPath) {
                observed.formUnion(current)
            }
            if crashedDuringLaunch(launchLog(logURL), launcherPath: launcherPath, since: start) {
                closeCrashedGame(observed, launcherPath: launcherPath, status: status)
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { process.terminate() }
                let terminationDeadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw CEFLaunchError.message("The KCD:MP client crashed. See \(logURL.path)")
            }
            Thread.sleep(forTimeInterval: 1)
        }
        process.waitUntilExit()
        let log = launchLog(logURL)
        if crashedDuringLaunch(log, launcherPath: launcherPath, since: start) {
            closeCrashedGame(observed, launcherPath: launcherPath, status: status)
            throw CEFLaunchError.message("The KCD:MP client crashed. See \(logURL.path)")
        }
        if let current = try? gameProcessIDs(launcherPath: launcherPath), !current.isEmpty {
            let tracked = observed.union(current)
            status("The launcher closed. Waiting for the game process to exit…")
            while !((try? gameProcessIDs(launcherPath: launcherPath)) ?? []).intersection(tracked).isEmpty {
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard process.terminationStatus == 0 else {
            throw CEFLaunchError.message("KCD:MP exited with code \(process.terminationStatus). Log: \(logURL.path)")
        }
    }

    private static func runWithoutCEF(launcherPath: String, address: String, name: String, password: String,
                                      steamEnvironment: [String: String], resourceURL: URL,
                                      version: String, status: (String) -> Void) throws {
        let script = resourceURL.appendingPathComponent("kcdmp-launch.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw CEFLaunchError.message("The app is missing its launch script.")
        }
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KCDMP CEF")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let logURL = logDirectory.appendingPathComponent("launch-direct-" + UUID().uuidString + ".log")
        let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CEFLaunchError.message("Could not create the launch log.") }
        let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--launcher", launcherPath, "--launch", address, name]
            + (password.isEmpty ? [] : [password])
        var environment = ProcessInfo.processInfo.environment
        environment.merge(steamEnvironment) { _, runningSteamValue in runningSteamValue }
        environment.removeValue(forKey: "WINELOADERNOEXEC")
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        status("No verified Mac CEF helper for KCD:MP \(version). Trying the official client directly…")
        try process.run()
        try supervise(process, launcherPath: launcherPath, logURL: logURL, status: status)
    }

    static func connectionArguments(launcher: URL, address: String, name: String, password: String) -> [String] {
        [launcher.path, "--connect", address, "--name", name]
            + (password.isEmpty ? [] : ["--token", password]) + ["--wait"]
    }

    static func preflight(launcherPath: String, steamEnvironment: [String: String], resourceURL: URL) throws -> CEFLaunchPlan {
        let selected = try selectedClient(launcherPath: launcherPath)
        let launcher = selected.launcher
        let prefix = selected.prefix
        let gameDirectory = launcher.deletingLastPathComponent()
        let digest = try clientHash(selected.client)
        guard digest == supportedClientHash else {
            throw CEFLaunchError.message("CEF compatibility supports only the verified KCD:MP \(supportedVersion) client.")
        }

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wine Forge/database.json")
        let database = try jsonObject(at: databaseURL)
        guard let bottles = database["bottles"] as? [[String: Any]],
              let bottle = bottles.first(where: { item in
                  guard let path = item["path"] as? String else { return false }
                  return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == prefix.path
              }),
              let bottleID = bottle["id"] as? String,
              let settings = bottleSettings(database["bottleSettings"], id: bottleID),
              let graphics = settings["graphics"] as? [String: Any],
              graphics["backend"] as? String == "d3dMetal" else {
            throw CEFLaunchError.message("The selected WineForge Steam bottle must use its configured D3DMetal backend.")
        }

        let selectedWine = steamEnvironment["WINE"] ?? ""
        let wine = URL(fileURLWithPath: selectedWine).standardizedFileURL.resolvingSymlinksInPath()
        guard wine.lastPathComponent == "wine", FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw CEFLaunchError.message("Start Windows Steam in the selected WineForge bottle before connecting.")
        }
        let engine = wine.deletingLastPathComponent().deletingLastPathComponent()
        let metal = URL(fileURLWithPath: steamEnvironment["D3DMETAL_RUNTIME_DIR"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wine Forge/Runtimes/D3DMetal").path)
        guard FileManager.default.isExecutableFile(atPath: engine.appendingPathComponent("bin/wineserver").path),
              FileManager.default.fileExists(atPath: metal.appendingPathComponent("external/D3DMetal.framework/D3DMetal").path) else {
            throw CEFLaunchError.message("The WineForge runtime for this Steam bottle is missing.")
        }

        let resources = resourceURL.appendingPathComponent("cef-compat/client_compat")
        let compatDLL = resources.appendingPathComponent("bin/KcdMpCefCompat.dll")
        let loader = resources.appendingPathComponent("loader/bin/kcdmp_compat_loader.exe")
        let watcher = resources.appendingPathComponent("loader/bin/kcdmp_compat_watcher.exe")
        for (label, url) in [("CEF DLL", compatDLL), ("CEF loader", loader), ("CEF watcher", watcher)] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CEFLaunchError.message("The app is missing its \(label). Rebuild the app from the complete project.")
            }
        }
        let preferences = try preferencesURL(prefix: prefix)
        _ = try jsonObject(at: preferences)

        var environment = ProcessInfo.processInfo.environment
        environment.merge(steamEnvironment) { _, runningSteamValue in runningSteamValue }
        let dllPath = [engine.appendingPathComponent("lib/dxmt"), engine.appendingPathComponent("lib/wine"),
                       engine.appendingPathComponent("lib/wine/i386-windows"), engine.appendingPathComponent("lib/wine/x86_64-windows"),
                       metal.appendingPathComponent("wine")].map(\.path).joined(separator: ":")
        let libraryPath = [engine.appendingPathComponent("lib/dxmt/x86_64-unix"), engine.appendingPathComponent("lib"),
                           engine.appendingPathComponent("lib/wine/x86_64-unix"), metal.appendingPathComponent("wine/x86_64-unix"),
                           metal.appendingPathComponent("external"), engine.appendingPathComponent("lib/gstreamer-1.0")]
            .map(\.path).joined(separator: ":")
        let shared = metal.appendingPathComponent("external/libd3dshared.dylib").path
        // Keep the exact prefix and server used by the Steam process. Changing either
        // can open a separate Wine session even when the bottle directory matches.
        environment["WINEPREFIX"] = steamEnvironment["WINEPREFIX"]
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = "-all"
        environment["WINE"] = wine.path
        environment["WINESERVER"] = steamEnvironment["WINESERVER"]
        environment["GRAPHICS_BACKEND"] = "d3dmetal"
        environment["ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"
        environment["D3DMETAL_RUNTIME_DIR"] = metal.path
        environment["D3DMETAL_FRAMEWORK_PATH"] = metal.appendingPathComponent("external/D3DMetal.framework/D3DMetal").path
        environment["D3DMETAL_LIBD3DSHARED_PATH"] = shared
        environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared
        environment["D3DMETAL_UNIXLIB_DIR"] = metal.appendingPathComponent("wine/x86_64-unix").path
        environment["WFDXCOMPAT_RUNTIME_DIR"] = engine.appendingPathComponent("lib/wfdxcompat").path
        environment["DXMT_RUNTIME_DIR"] = engine.appendingPathComponent("lib/dxmt").path
        let overrides = settings["dllOverrides"] as? String ?? ""
        environment["WINEDLLOVERRIDES"] = "dxgi,d3d10,d3d10core,d3d11,d3d12=n,b;mscoree,mshtml="
            + (overrides.isEmpty ? "" : ";" + overrides)
        environment["WINEDLLPATH"] = dllPath
        environment["DYLD_LIBRARY_PATH"] = libraryPath
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPath
        environment.removeValue(forKey: "WINELOADERNOEXEC")
        return CEFLaunchPlan(launcher: launcher, gameDirectory: gameDirectory, prefix: prefix,
                             preferences: preferences, wine: wine, environment: environment,
                             compatDLL: compatDLL, loader: loader, watcher: watcher)
    }

    static func run(launcherPath: String, address: String, name: String, password: String,
                    serverVersion: String?, steamEnvironment: [String: String], resourceURL: URL,
                    status: (String) -> Void) throws {
        status("Checking the running Steam Wine session…")
        try verifyRunningWineServer(environment: steamEnvironment)
        try verifyGameNotRunning(launcherPath: launcherPath)
        let prepared = try prepareClient(launcherPath: launcherPath, steamEnvironment: steamEnvironment,
                                         serverVersion: serverVersion, status: status)
        if !prepared.cefSupported {
            try runWithoutCEF(launcherPath: launcherPath, address: address, name: name, password: password,
                              steamEnvironment: steamEnvironment, resourceURL: resourceURL,
                              version: prepared.version, status: status)
            return
        }
        let plan = try preflight(launcherPath: launcherPath, steamEnvironment: steamEnvironment, resourceURL: resourceURL)
        let fileManager = FileManager.default
        let original = try jsonObject(at: plan.preferences)
        let logDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KCDMP CEF")
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let logURL = logDirectory.appendingPathComponent("launch-" + UUID().uuidString + ".log")
        let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CEFLaunchError.message("Could not create the CEF launch log.") }
        let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? logHandle.close() }
        let stage = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("kcdmp-cef-session-" + UUID().uuidString)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        var watcher: Process?
        var launcher: Process?
        defer {
            stopWatcher(watcher)
            try? fileManager.removeItem(at: stage)
        }
        let ready = stage.appendingPathComponent("watcher.ready")
        var preferencesChanged = false
        var failure: Error?

        do {
            let watch = Process()
            watch.executableURL = plan.wine
            watch.arguments = [plan.watcher.path,
                               "--image", plan.windowsPath(plan.gameDirectory.appendingPathComponent("KingdomCome.exe")),
                               "--dll", plan.windowsPath(plan.compatDLL),
                               "--loader", plan.windowsPath(plan.loader),
                               "--ready-file", plan.windowsPath(ready)]
            watch.environment = plan.environment
            watch.standardOutput = logHandle
            watch.standardError = logHandle
            try watch.run()
            watcher = watch
            let readyDeadline = Date().addingTimeInterval(15)
            while !fileManager.fileExists(atPath: ready.path) {
                if !watch.isRunning {
                    throw CEFLaunchError.message("The CEF watcher refused startup. Close any existing KCD2 game or Wine debugger, then retry. Steam can stay open. Log: \(logURL.path)")
                }
                if Date() >= readyDeadline { throw CEFLaunchError.message("CEF watcher readiness timed out. See \(logURL.path)") }
                Thread.sleep(forTimeInterval: 0.05)
            }

            var enabled = original
            enabled["server_ui"] = true
            try writePreferences(enabled, to: plan.preferences)
            preferencesChanged = true
            status("Connecting with KCD:MP \(supportedVersion) CEF…")

            let gameLaunch = Process()
            gameLaunch.executableURL = plan.wine
            gameLaunch.arguments = connectionArguments(launcher: plan.launcher, address: address,
                                                       name: name, password: password)
            gameLaunch.currentDirectoryURL = plan.gameDirectory
            gameLaunch.environment = plan.environment
            gameLaunch.standardOutput = logHandle
            gameLaunch.standardError = logHandle
            try gameLaunch.run()
            launcher = gameLaunch

            let injectionDeadline = Date().addingTimeInterval(150)
            while watch.isRunning {
                if !gameLaunch.isRunning {
                    throw earlyLauncherFailure(logURL: logURL)
                }
                if Date() >= injectionDeadline { throw CEFLaunchError.message("CEF loading timed out. Log: \(logURL.path)") }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !gameLaunch.isRunning { throw earlyLauncherFailure(logURL: logURL) }
            guard watch.terminationStatus == 0 else {
                throw CEFLaunchError.message("CEF loading was refused. Log: \(logURL.path)")
            }
            status("CEF loaded. Waiting for the game to close…")
            try supervise(gameLaunch, launcherPath: launcherPath, logURL: logURL, status: status)
        } catch {
            failure = error
        }

        if failure != nil, let launcher, launcher.isRunning {
            stopWatcher(watcher)
            status("The previous game is still open. Close only that game or its Wine debugger to retry Connect. Steam can stay open.")
            launcher.waitUntilExit()
        }

        if preferencesChanged {
            do {
                var current = try jsonObject(at: plan.preferences)
                if let previousValue = original["server_ui"] { current["server_ui"] = previousValue }
                else { current.removeValue(forKey: "server_ui") }
                try writePreferences(current, to: plan.preferences)
            } catch {
                if failure == nil { failure = CEFLaunchError.message("Could not restore KCD:MP preferences: \(error.localizedDescription)") }
                else { status("Could not restore KCD:MP preferences. See \(logURL.path)") }
            }
        }
        if let failure { throw failure }
    }

    private static func stopWatcher(_ watcher: Process?) {
        guard let watcher else { return }
        if watcher.isRunning {
            watcher.terminate()
            let deadline = Date().addingTimeInterval(5)
            while watcher.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if watcher.isRunning { _ = Darwin.kill(watcher.processIdentifier, SIGKILL) }
        }
        watcher.waitUntilExit()
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CEFLaunchError.message("Invalid JSON in \(url.path)")
        }
        return object
    }

    private static func earlyLauncherFailure(logURL: URL) -> CEFLaunchError {
        let log = (try? Data(contentsOf: logURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if crashedGame(log) {
            return .message("The KCD:MP client crashed before CEF loaded. Log: \(logURL.path)")
        }
        if log.contains("protocol") && log.contains("not supported") {
            return .message("This server uses a different KCD:MP protocol. Check that the server is updated. Log: \(logURL.path)")
        }
        if log.contains("no answer within") {
            return .message("The server did not answer. Choose another server. Log: \(logURL.path)")
        }
        return .message("KCD:MP exited before CEF loaded. Log: \(logURL.path)")
    }

    private static func bottleSettings(_ raw: Any?, id: String) -> [String: Any]? {
        if let dictionary = raw as? [String: Any] { return dictionary[id] as? [String: Any] }
        if let entries = raw as? [Any] {
            for index in stride(from: 0, to: entries.count - 1, by: 2) {
                if entries[index] as? String == id { return entries[index + 1] as? [String: Any] }
            }
        }
        return nil
    }

    private static func preferencesURL(prefix: URL) throws -> URL {
        let users = prefix.appendingPathComponent("drive_c/users")
        let preferred = users.appendingPathComponent(NSUserName() + "/AppData/Local/KcdMp/launcher.json")
        let choices = (try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil))
            .map { $0.appendingPathComponent("AppData/Local/KcdMp/launcher.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let selected: URL
        if FileManager.default.fileExists(atPath: preferred.path) { selected = preferred }
        else if choices.count == 1 { selected = choices[0] }
        else { throw CEFLaunchError.message("Could not identify KCD:MP preferences in this Steam bottle.") }
        let values = try selected.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CEFLaunchError.message("KCD:MP preferences cannot be a symbolic link.") }
        return selected
    }

    private static func writePreferences(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        var pattern = Array(url.deletingLastPathComponent().appendingPathComponent(".cef-test-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&pattern)
        guard descriptor >= 0 else { throw CEFLaunchError.message("Could not create temporary KCD:MP preferences.") }
        let temporary = String(cString: pattern)
        var renamed = false
        defer {
            _ = close(descriptor)
            if !renamed { _ = unlink(temporary) }
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw CEFLaunchError.message("Could not write KCD:MP preferences.") }
                offset += written
            }
        }
        guard rename(temporary, url.path) == 0 else {
            throw CEFLaunchError.message("Could not replace KCD:MP preferences.")
        }
        renamed = true
    }
}
