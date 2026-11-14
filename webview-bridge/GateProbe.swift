import Foundation
import Darwin

@main
struct GateProbe {
    static func main() {
        guard CommandLine.arguments.count == 3 else { fputs("Usage: gate-probe Steam_launcher probe_exe\n",stderr);exit(2) }
        do {
            let launcher = CommandLine.arguments[1]
            let probe = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            guard FileManager.default.fileExists(atPath: probe.path) else { throw CocoaError(.fileNoSuchFile) }
            let steam = try environmentForRunningSteam(launcherPath: launcher)
            try verifyRunningWineServer(environment: steam)
            let cefGuard = probe.lastPathComponent == "cef-guard-probe.exe"
            if !cefGuard { try verifyGameNotRunning(launcherPath: launcher) }
            guard let wine = steam["WINE"] else { throw SteamProcessError.missingEnvironment }
            for wrongTarget in (cefGuard ? [false] : [false, true]) {
                var environment = ProcessInfo.processInfo.environment
                environment.merge(steam) { _, value in value }
                for name in Array(environment.keys) where name.hasPrefix("KCDMP_WEBKIT_") { environment.removeValue(forKey: name) }
                environment.removeValue(forKey: "WINELOADERNOEXEC")
                if wrongTarget {
                    environment["KCDMP_WEBKIT_BRIDGE_ENABLED"] = "1"
                    environment["KCDMP_WEBKIT_BRIDGE_EXPECTED_EXE"] = "C:\\not-the-authorized-process.exe"
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: wine)
                process.currentDirectoryURL = probe.deletingLastPathComponent()
                process.arguments = cefGuard ? [probe.path] : [probe.path, "--negative"]
                process.environment = environment
                try process.run()
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { process.terminate(); process.waitUntilExit(); throw NSError(domain:"GateProbe",code:124) }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NSError(domain:"GateProbe",code:Int(process.terminationStatus)) }
                print(cefGuard ? "CEF guard controls verified in isolated probe process" : (wrongTarget ? "Wrong process gate verified" : "Missing opt-in gate verified"))
            }
        } catch { fputs("Gate tests failed: \(error)\n",stderr);exit(1) }
    }
}
