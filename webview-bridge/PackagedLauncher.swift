import AppKit
import Foundation
import Darwin

// File pickers and startup alerts need a finished NSApplication launch.
final class PackagedAppDelegate: NSObject, NSApplicationDelegate {
    private var host: BridgeHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let prepared = try PackagedLauncher.prepare() else { NSApp.terminate(nil); return }
            let host = BridgeHost(configuration: prepared.configuration)
            host.managedPlacement = prepared.placement
            self.host = host
            NSApp.delegate = host
            host.applicationDidFinishLaunching(notification)
        } catch {
            let alert = NSAlert()
            alert.messageText = "KCD2MP Mac"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(2)
        }
    }
}

struct PackagedLauncher {
    struct Target: Decodable {
        let launcher_sha256: String
        let client_sha256: String
        let client_version: String
        let bridge_sha256: String
        let cef_helper_sha256: String
        let dock_helper_abi: Int
    }
    let configuration: BridgeConfiguration
    let placement: LoaderPlacement

    static func prepare() throws -> PackagedLauncher? {
        guard let resources = Bundle.main.resourceURL else { throw PlacementError.message("The app resources are missing.") }
        let target = try JSONDecoder().decode(Target.self, from: Data(contentsOf: resources.appendingPathComponent("launcher-target.json")))
        guard target.client_sha256 == CEFClientTarget.sha256, target.client_version == CEFClientTarget.version else {
            throw PlacementError.message("The app contains mismatched client compatibility files.")
        }
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "KCDMPLauncherPath").map { ($0 as NSString).expandingTildeInPath }
        let path: URL
        if let saved, FileManager.default.fileExists(atPath: saved) {
            path = URL(fileURLWithPath: saved)
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose KcdMp_launcher.exe"
            panel.message = "Select KcdMp_launcher.exe beside KingdomCome.exe in your Windows Steam bottle."
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let selected = panel.url else { return nil }
            path = selected
        }
        let launcher = path.standardizedFileURL.resolvingSymlinksInPath()
        let game = launcher.deletingLastPathComponent()
        guard launcher.lastPathComponent == "KcdMp_launcher.exe", launcher.path.contains("/drive_c/"),
              FileManager.default.fileExists(atPath: game.appendingPathComponent("KingdomCome.exe").path),
              FileManager.default.fileExists(atPath: game.appendingPathComponent("ui/launcher.html").path) else {
            defaults.removeObject(forKey: "KCDMPLauncherPath")
            throw PlacementError.message("Select KcdMp_launcher.exe from the complete multiplayer ZIP beside KingdomCome.exe.")
        }
        guard try fileSHA256(launcher) == target.launcher_sha256,
              try fileSHA256(game.appendingPathComponent("KcdMp_client.dll")) == target.client_sha256 else {
            defaults.removeObject(forKey: "KCDMPLauncherPath")
            throw PlacementError.message("This app supports the official KCD:MP \(target.client_version) files. Install its matching Mac build and keep all multiplayer ZIP files together.")
        }
        let steam = try environmentForRunningSteam(launcherPath: launcher.path)
        try verifyRunningWineServer(environment: steam)
        try verifyGameNotRunning(launcherPath: launcher.path)
        guard try launcherProcessIDs(launcherPath: launcher.path).isEmpty else {
            throw PlacementError.message("The Windows KCD:MP launcher is already running. Close that launcher and try again. Steam can stay open.")
        }
        let helper = resources.appendingPathComponent("cef-compat/client_compat/bin/KcdMpCefCompat.dll")
        guard try fileSHA256(helper) == target.cef_helper_sha256 else { throw PlacementError.message("The bundled CEF helper is damaged.") }
        let dockData = try Data(contentsOf: resources.appendingPathComponent("libKcdMpDockPolicy.dylib"))
        guard target.dock_helper_abi == 1, dockData.range(of: Data("KCDMP_DOCK_POLICY_ABI_1".utf8)) != nil else {
            throw PlacementError.message("The bundled launcher Dock helper is damaged.")
        }
        let runtime = resources.appendingPathComponent("cef-compat/client_compat/loader/bin")
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/KCD2MP Mac/" + UUID().uuidString)
        let arguments = ["KCD2MP Mac", "--steam-launcher", launcher.path, "--exe", launcher.path,
                         "--allowed-root", game.appendingPathComponent("ui").path, "--log-directory", logs.path, "--allow-join",
                         "--cef-helper", helper.path, "--cef-loader", runtime.appendingPathComponent("kcdmp_compat_loader.exe").path,
                         "--cef-watcher", runtime.appendingPathComponent("kcdmp_compat_watcher.exe").path,
                         "--cef-client-sha256", target.client_sha256]
        let config = try BridgeConfiguration(arguments: arguments)
        let placement = try LoaderPlacement(directory: game, loader: resources.appendingPathComponent("WebView2Loader.dll"), expectedHash: target.bridge_sha256)
        defaults.set(launcher.path, forKey: "KCDMPLauncherPath")
        return PackagedLauncher(configuration: config, placement: placement)
    }
}
