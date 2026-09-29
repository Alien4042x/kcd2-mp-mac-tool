import Foundation
import Darwin

enum SteamProcessError: LocalizedError {
    case notRunning
    case missingEnvironment

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Start Windows Steam in the same Wine bottle, then try Connect again."
    case .missingEnvironment:
            return "Could not read the running Windows Steam process. Restart it in your Wine bottle and try again."
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

func environmentForRunningSteam(launcherPath: String) throws -> [String: String] {
    guard let bottleRange = launcherPath.range(of: "/drive_c/") else {
        throw SteamProcessError.notRunning
    }
    let selectedBottle = URL(fileURLWithPath: String(launcherPath[..<bottleRange.lowerBound]))
        .standardizedFileURL.resolvingSymlinksInPath().path
    for pid in try steamProcessIDs() {
        guard let snapshot = processSnapshot(pid: pid),
              let executable = snapshot.arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "steam.exe",
              let steamBottleRange = executable.range(of: "/drive_c/"),
              URL(fileURLWithPath: String(executable[..<steamBottleRange.lowerBound]))
                  .standardizedFileURL.resolvingSymlinksInPath().path == selectedBottle
        else { continue }
        if let prefix = snapshot.environment["WINEPREFIX"],
           URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path != selectedBottle {
            throw SteamProcessError.missingEnvironment
        }
        if !FileManager.default.fileExists(atPath: selectedBottle + "/cxbottle.conf") {
            guard let wine = snapshot.environment["WINE"],
                  FileManager.default.isExecutableFile(atPath: wine) else {
                throw SteamProcessError.missingEnvironment
            }
        }
        return snapshot.environment
    }
    throw SteamProcessError.notRunning
}
