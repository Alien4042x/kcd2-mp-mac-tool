import Foundation
import Darwin

enum SteamProcessError: LocalizedError {
    case notRunning
    case missingEnvironment
    case ambiguousSession
    case serverNotRunning

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

private func steamProcessIDs() throws -> [Int32] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "steam.exe"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0) }
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
    for pid in try steamProcessIDs() {
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
        if let selectedIdentity, selectedIdentity != identity { throw SteamProcessError.ambiguousSession }
        selectedIdentity = identity
        selectedEnvironment = environment
    }
    if let selectedEnvironment { return selectedEnvironment }
    if foundSteam { throw SteamProcessError.missingEnvironment }
    throw SteamProcessError.notRunning
}
