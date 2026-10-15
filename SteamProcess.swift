import Foundation
import Darwin

enum SteamProcessError: LocalizedError {
    case notRunning
    case missingEnvironment
    case ambiguousSession
    case serverNotRunning
    case gameAlreadyRunning
    case debuggerStillRunning
    case processInspectionFailed

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Start Windows Steam in the same Wine bottle, then try Connect again."
        case .missingEnvironment:
            return "Could not verify the running Steam Wine prefix and runtime. Restart Windows Steam in the selected bottle and try again."
        case .ambiguousSession:
            return "Multiple Windows Steam sessions use this bottle with different Wine settings. Close the extra Steam session and try again."
        case .serverNotRunning:
            return "Windows Steam is visible, but its Wine server is not running in the selected bottle. Restart Steam in that bottle and try again."
        case .gameAlreadyRunning:
            return "KCD2 is already running in this Steam bottle. Close the game or its Wine debugger before connecting again. Steam can stay open."
        case .debuggerStillRunning:
            return "A Wine debugger is still open in this Steam bottle. Close it before connecting again. Steam can stay open."
        case .processInspectionFailed:
            return "Could not check whether KCD2 is still running. Try Connect again after closing the game."
        }
    }
}

private struct SteamProcessSnapshot {
    let arguments: [String]
    let environment: [String: String]
}

private func processSnapshot(pid: Int32) -> SteamProcessSnapshot? {
    var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    var bytes = [UInt8](repeating: 0, count: size)
    guard bytes.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0 else {
        return nil
    }
    bytes = Array(bytes.prefix(size))
    let argumentCount = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    guard (1...256).contains(argumentCount) else { return nil }

    var offset = MemoryLayout<Int32>.size
    func readString() -> String? {
        guard offset < bytes.count else { return nil }
        let start = offset
        while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
        guard offset < bytes.count else { return nil }
        let result = String(decoding: bytes[start..<offset], as: UTF8.self)
        offset += 1
        return result
    }
    func skipZeros() {
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
    }

    guard readString() != nil else { return nil } // Wine loader path
    skipZeros()
    var arguments: [String] = []
    for _ in 0..<argumentCount {
        guard let argument = readString() else { return nil }
        arguments.append(argument)
    }
    skipZeros()
    var environment: [String: String] = [:]
    while let entry = readString(), !entry.isEmpty {
        guard let separator = entry.firstIndex(of: "=") else { continue }
        environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
    }
    return SteamProcessSnapshot(arguments: arguments, environment: environment)
}

private func processIDs(matching name: String) throws -> [Int32] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", name]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
        throw SteamProcessError.processInspectionFailed
    }
    return String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0) }
}

private func wineExecutablePath(_ argument: String, prefix: String) -> String? {
    let path = argument.replacingOccurrences(of: "\\", with: "/")
    if path.hasPrefix("/") { return path }
    guard path.count >= 3, path[path.index(path.startIndex, offsetBy: 1)] == ":",
          path[path.index(path.startIndex, offsetBy: 2)] == "/" else { return nil }
    switch path.prefix(1).lowercased() {
    case "c": return prefix + "/drive_c" + path.dropFirst(2)
    case "z": return String(path.dropFirst(2))
    default: return nil
    }
}

private func steamGameLanguage(prefix: String) -> [String: String] {
    let manifest = URL(fileURLWithPath: prefix)
        .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/appmanifest_1771300.acf")
    guard let contents = try? String(contentsOf: manifest, encoding: .utf8) else { return [:] }
    let language = contents.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "\"", omittingEmptySubsequences: false)
        guard fields.count >= 4, fields[1] == "language" else { return nil }
        return String(fields[3])
    }.first
    guard let language,
          language.range(of: #"^[A-Za-z_-]+$"#, options: .regularExpression) != nil else { return [:] }
    let locales = [
        "czech": "cs_CZ.UTF-8", "english": "en_US.UTF-8", "german": "de_DE.UTF-8",
        "french": "fr_FR.UTF-8", "italian": "it_IT.UTF-8", "spanish": "es_ES.UTF-8",
        "polish": "pl_PL.UTF-8", "russian": "ru_RU.UTF-8", "japanese": "ja_JP.UTF-8",
        "korean": "ko_KR.UTF-8", "portuguese": "pt_PT.UTF-8", "brazilian": "pt_BR.UTF-8",
        "turkish": "tr_TR.UTF-8", "ukrainian": "uk_UA.UTF-8", "schinese": "zh_CN.UTF-8",
        "tchinese": "zh_TW.UTF-8"
    ]
    var result = ["SteamAppLanguage": language]
    if let locale = locales[language] {
        result["LANG"] = locale
        result["LC_ALL"] = locale
    }
    return result
}

func gameProcessIDs(launcherPath: String) throws -> Set<Int32> {
    guard let bottleRange = launcherPath.range(of: "/drive_c/") else {
        throw SteamProcessError.notRunning
    }
    let bottle = URL(fileURLWithPath: String(launcherPath[..<bottleRange.lowerBound]))
        .standardizedFileURL.resolvingSymlinksInPath().path
    let expected = URL(fileURLWithPath: launcherPath).deletingLastPathComponent()
        .appendingPathComponent("KingdomCome.exe").standardizedFileURL.resolvingSymlinksInPath().path
    var found = Set<Int32>()
    for pid in try processIDs(matching: "KingdomCome.exe") {
        guard let snapshot = processSnapshot(pid: pid), let executable = snapshot.arguments.first,
              let prefix = snapshot.environment["WINEPREFIX"],
              URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path == bottle,
              let processPath = wineExecutablePath(executable, prefix: bottle),
              URL(fileURLWithPath: processPath).standardizedFileURL.resolvingSymlinksInPath().path
                  .caseInsensitiveCompare(expected) == .orderedSame
        else { continue }
        found.insert(pid)
    }
    return found
}

func debuggerProcessIDs(launcherPath: String) throws -> Set<Int32> {
    guard let bottleRange = launcherPath.range(of: "/drive_c/") else {
        throw SteamProcessError.notRunning
    }
    let bottle = URL(fileURLWithPath: String(launcherPath[..<bottleRange.lowerBound]))
        .standardizedFileURL.resolvingSymlinksInPath().path
    var found = Set<Int32>()
    for pid in try processIDs(matching: "winedbg.exe") {
        guard let snapshot = processSnapshot(pid: pid), let executable = snapshot.arguments.first,
              executable.replacingOccurrences(of: "\\", with: "/")
                  .split(separator: "/").last?.lowercased() == "winedbg.exe",
              let prefix = snapshot.environment["WINEPREFIX"],
              URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path == bottle
        else { continue }
        found.insert(pid)
    }
    return found
}

func sessionProcessIDs(launcherPath: String) throws -> Set<Int32> {
    try gameProcessIDs(launcherPath: launcherPath).union(debuggerProcessIDs(launcherPath: launcherPath))
}

func verifyGameNotRunning(launcherPath: String) throws {
    if !(try gameProcessIDs(launcherPath: launcherPath)).isEmpty {
        throw SteamProcessError.gameAlreadyRunning
    }
    if !(try debuggerProcessIDs(launcherPath: launcherPath)).isEmpty {
        throw SteamProcessError.debuggerStillRunning
    }
}

func verifyRunningWineServer(environment: [String: String]) throws {
    guard let serverPath = environment["WINESERVER"] else {
        throw SteamProcessError.missingEnvironment
    }
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: serverPath)
    probe.arguments = ["-k0"] // Signal 0 checks this prefix without stopping its wineserver.
    probe.environment = environment
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do { try probe.run() } catch { throw SteamProcessError.serverNotRunning }
    let deadline = Date().addingTimeInterval(3)
    while probe.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if probe.isRunning {
        probe.terminate()
        let grace = Date().addingTimeInterval(1)
        while probe.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if probe.isRunning { _ = Darwin.kill(probe.processIdentifier, SIGKILL) }
    }
    probe.waitUntilExit()
    guard probe.terminationStatus == 0 else { throw SteamProcessError.serverNotRunning }
}

func environmentForRunningSteam(launcherPath: String) throws -> [String: String] {
    guard let bottleRange = launcherPath.range(of: "/drive_c/") else {
        throw SteamProcessError.notRunning
    }
    let selectedBottle = URL(fileURLWithPath: String(launcherPath[..<bottleRange.lowerBound]))
        .standardizedFileURL.resolvingSymlinksInPath().path
    let isCrossOver = FileManager.default.fileExists(atPath: selectedBottle + "/cxbottle.conf")
    var foundSteam = false
    var selectedEnvironment: [String: String]?
    var selectedIdentity: [String]?
    for pid in try processIDs(matching: "steam.exe") {
        guard let snapshot = processSnapshot(pid: pid),
              let executable = snapshot.arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "steam.exe",
              let steamBottleRange = executable.range(of: "/drive_c/"),
              URL(fileURLWithPath: String(executable[..<steamBottleRange.lowerBound]))
                  .standardizedFileURL.resolvingSymlinksInPath().path == selectedBottle
        else { continue }
        foundSteam = true
        guard let prefix = snapshot.environment["WINEPREFIX"], !prefix.isEmpty,
              URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path == selectedBottle else { continue }
        let server: String
        let identity: [String]
        if isCrossOver {
            guard let bottleName = snapshot.environment["CX_BOTTLE"], !bottleName.isEmpty,
                  let root = snapshot.environment["CX_ROOT"], root.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: root + "/bin/wine"),
                  let runningServer = snapshot.environment["WINESERVER"] else { continue }
            server = runningServer
            identity = [prefix, root, bottleName, server]
        } else {
            guard let wine = snapshot.environment["WINE"], wine.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: wine) else { continue }
            server = snapshot.environment["WINESERVER"] ??
                URL(fileURLWithPath: wine).deletingLastPathComponent().appendingPathComponent("wineserver").path
            identity = [prefix, wine, server]
        }
        guard server.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: server) else { continue }
        var environment = snapshot.environment
        environment["WINESERVER"] = server
        environment.merge(steamGameLanguage(prefix: selectedBottle)) { _, gameValue in gameValue }
        if let selectedIdentity, selectedIdentity != identity { throw SteamProcessError.ambiguousSession }
        selectedIdentity = identity
        selectedEnvironment = environment
    }
    if let selectedEnvironment { return selectedEnvironment }
    if foundSteam { throw SteamProcessError.missingEnvironment }
    throw SteamProcessError.notRunning
}
