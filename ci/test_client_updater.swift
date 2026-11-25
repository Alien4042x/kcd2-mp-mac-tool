import Foundation
import Darwin

@main
struct ClientUpdaterTests {
    static func failure(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected failure") } catch {}
    }

    static func main() throws {
        let target = ClientUpdateTarget(version: "0.51.0", launcherHash: "launcher-51", clientHash: "client-51")
        let correct = ClientFileHashes(launcher: target.launcherHash, client: target.clientHash)
        let old = ClientFileHashes(launcher: "launcher-50", client: "client-50")
        let response = "updater\nnewest release: 0.51.0 (Windows, x64, protocol 124) - client.zip, 123 bytes\n"
        var cases = 0

        var calls: [String] = []
        try OfficialClientUpdater.ensure(target: target, hashes: { correct }, run: { calls.append($0); return response }, status: { _ in })
        precondition(calls.isEmpty)
        cases += 1

        for initial in [old, ClientFileHashes(launcher: target.launcherHash, client: nil),
                        ClientFileHashes(launcher: "changed", client: target.clientHash)] {
            var installed = initial
            calls = []
            try OfficialClientUpdater.ensure(target: target, hashes: { installed }, run: { action in
                calls.append(action)
                if action == "--update" { installed = correct }
                return response
            }, status: { _ in })
            precondition(calls == ["--update-check", "--update"] && installed.matches(target))
            cases += 1
        }

        for invalid in ["", "up to date", "newest release: null", "newest release: 0",
                        "newest release: 0.51.0\nnewest release: 0.51.0",
                        "newest release: 0.52.0", "newest release: 0.50.0"] {
            calls = []
            failure {
                try OfficialClientUpdater.ensure(target: target, hashes: { old }, run: { calls.append($0); return invalid }, status: { _ in })
            }
            precondition(calls == ["--update-check"], "Invalid or unsupported response must not apply an update")
            cases += 1
        }

        calls = []
        failure {
            try OfficialClientUpdater.ensure(target: target, hashes: { throw ClientUpdateError.message("read denied") },
                                             run: { calls.append($0); return response }, status: { _ in })
        }
        precondition(calls.isEmpty, "A failed read is not a missing client")
        cases += 1

        for failAction in ["--update-check", "--update"] {
            calls = []
            failure {
                try OfficialClientUpdater.ensure(target: target, hashes: { old }, run: { action in
                    calls.append(action)
                    if action == failAction { throw ClientUpdateError.message("network or updater failure") }
                    return response
                }, status: { _ in })
            }
            precondition(calls.last == failAction)
            cases += 1
        }

        for resulting in [old, ClientFileHashes(launcher: "wrong", client: target.clientHash),
                          ClientFileHashes(launcher: target.launcherHash, client: nil)] {
            var reads = 0
            failure {
                try OfficialClientUpdater.ensure(target: target, hashes: { reads += 1; return reads == 1 ? old : resulting },
                                                 run: { _ in response }, status: { _ in })
            }
            precondition(reads == 2, "Updater success must be followed by exact file verification")
            cases += 1
        }
        var reads = 0
        failure {
            try OfficialClientUpdater.ensure(target: target, hashes: {
                reads += 1
                if reads == 2 { throw ClientUpdateError.message("updated file unreadable") }
                return old
            }, run: { _ in response }, status: { _ in })
        }
        precondition(reads == 2)
        cases += 1

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kcd2mp-updater-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func process(_ command: String) -> OfficialUpdateProcess {
            OfficialUpdateProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                                  directory: scratch, environment: ProcessInfo.processInfo.environment)
        }
        let text = try process("printf 'newest release: 0.51.0\\n'").run("--update-check", cancellation: UpdateCancellation(), timeout: 3)
        let parsedVersion = try OfficialClientUpdater.newestVersion(in: text)
        precondition(parsedVersion == target.version)
        cases += 1
        failure { _ = try process("printf 'download failed\\n'; exit 7").run("--update", cancellation: UpdateCancellation(), timeout: 3) }
        cases += 1
        failure { _ = try process("printf 'unused'").run("--connect", cancellation: UpdateCancellation(), timeout: 3) }
        cases += 1
        let started = Date()
        failure { _ = try process("trap '' TERM; exec sleep 20").run("--update-check", cancellation: UpdateCancellation(), timeout: 0.1) }
        precondition(Date().timeIntervalSince(started) < 4, "A stuck updater must have bounded cleanup")
        cases += 1
        let cancellation = UpdateCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        failure { _ = try process("exec sleep 20").run("--update", cancellation: cancellation, timeout: 10) }
        cases += 1

        let launcher = scratch.appendingPathComponent("drive_c/Game Folder/KcdMp_launcher.exe")
        let steam = ["WINEPREFIX": scratch.path, "WINE": "/bin/sh", "WINESERVER": "/bin/true", "SteamAppLanguage": "czech"]
        let plain = try OfficialUpdateProcess.command(launcher: launcher, steam: steam)
        precondition(plain.arguments == [launcher.path] && plain.environment["WINEPREFIX"] == scratch.path
                     && plain.environment["SteamAppLanguage"] == "czech" && plain.environment["WINEDEBUG"] == "-all")
        cases += 1
        let root = scratch.appendingPathComponent("CrossOver App")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let fakeWine = root.appendingPathComponent("bin/wine")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeWine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeWine.path)
        try Data().write(to: scratch.appendingPathComponent("cxbottle.conf"))
        var crossover = steam
        crossover["CX_ROOT"] = root.path
        crossover["CX_BOTTLE"] = "KCD Bottle"
        let cx = try OfficialUpdateProcess.command(launcher: launcher, steam: crossover)
        precondition(cx.arguments == ["--bottle", "KCD Bottle", "--cx-app", "C:\\Game Folder\\KcdMp_launcher.exe", "--"])
        precondition(cx.environment["WINEPREFIX"] == scratch.path)
        failure { _ = try OfficialUpdateProcess.command(launcher: launcher, steam: steam) }
        cases += 1
        print("Client updater checks passed: \(cases) cases, including old/missing files, invalid responses, failures, timeout, cancellation and CrossOver arguments")
    }
}
