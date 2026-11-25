import AppKit
import Foundation
import Darwin

// File pickers and startup alerts need a finished NSApplication launch.
final class PackagedAppDelegate: NSObject, NSApplicationDelegate {
    private var host: BridgeHost?
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private let cancellation = UpdateCancellation()
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let selection = try PackagedLauncher.select() else { NSApp.terminate(nil); return }
            showProgress()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try PackagedLauncher.prepare(selection, cancellation: self.cancellation) { text in
                        DispatchQueue.main.async { self.progressLabel?.stringValue = text }
                    }
                }
                DispatchQueue.main.async {
                    self.progressWindow?.close()
                    self.progressWindow = nil
                    self.progressLabel = nil
                    if self.quitting {
                        if case .success(let prepared) = result { try? prepared.placement.cleanup() }
                        NSApp.reply(toApplicationShouldTerminate: true)
                        return
                    }
                    do {
                        let prepared = try result.get()
                        let host = BridgeHost(configuration: prepared.configuration)
                        host.managedPlacement = prepared.placement
                        self.host = host
                        NSApp.delegate = host
                        host.applicationDidFinishLaunching(notification)
                    } catch { self.present(error) }
                }
            }
        } catch { present(error) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard progressWindow != nil else { return .terminateNow }
        quitting = true
        cancellation.cancel()
        progressLabel?.stringValue = "Cancelling the multiplayer update…"
        return .terminateLater
    }

    @objc private func cancelStartup() { NSApp.terminate(nil) }

    private func showProgress() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "KCD2MP Mac"
        let label = NSTextField(wrappingLabelWithString: "Preparing KCD:MP…")
        label.frame = NSRect(x: 24, y: 64, width: 372, height: 58)
        window.contentView?.addSubview(label)
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 26, width: 20, height: 20))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        window.contentView?.addSubview(spinner)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelStartup))
        cancel.frame = NSRect(x: 306, y: 18, width: 90, height: 32)
        window.contentView?.addSubview(cancel)
        progressLabel = label
        progressWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "KCD2MP Mac"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        exit(2)
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

    struct Selection {
        let resources: URL
        let target: Target
        let launcher: URL
    }

    static func select() throws -> Selection? {
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
              FileManager.default.fileExists(atPath: game.appendingPathComponent("KingdomCome.exe").path) else {
            defaults.removeObject(forKey: "KCDMPLauncherPath")
            throw PlacementError.message("Select KcdMp_launcher.exe from the complete multiplayer ZIP beside KingdomCome.exe.")
        }
        defaults.set(launcher.path, forKey: "KCDMPLauncherPath")
        return Selection(resources: resources, target: target, launcher: launcher)
    }

    static func prepare(_ selection: Selection, cancellation: UpdateCancellation,
                        status: (String) -> Void) throws -> PackagedLauncher {
        let resources = selection.resources, target = selection.target, launcher = selection.launcher
        let game = launcher.deletingLastPathComponent()
        let lease = try LauncherFolderLease(directory: game)
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
        let bridge = resources.appendingPathComponent("WebView2Loader.dll")
        guard try fileSHA256(bridge) == target.bridge_sha256 else {
            throw PlacementError.message("The bundled WebKit bridge is damaged.")
        }
        let runtime = resources.appendingPathComponent("cef-compat/client_compat/loader/bin")
        for name in ["kcdmp_compat_loader.exe", "kcdmp_compat_watcher.exe"] {
            guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent(name).path) else {
                throw PlacementError.message("A bundled CEF loader component is missing.")
            }
        }
        let expected = ClientUpdateTarget(version: target.client_version, launcherHash: target.launcher_sha256,
                                          clientHash: target.client_sha256)
        func optionalHash(_ url: URL) throws -> String? {
            do { return try fileSHA256(url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        }
        try OfficialClientUpdater.ensure(target: expected, hashes: {
            try ClientFileHashes(launcher: optionalHash(launcher), client: optionalHash(game.appendingPathComponent("KcdMp_client.dll")))
        }, run: { action in
            try verifyGameNotRunning(launcherPath: launcher.path)
            guard try launcherProcessIDs(launcherPath: launcher.path).isEmpty else {
                throw PlacementError.message("The Windows KCD:MP launcher is already running. Close it before updating.")
            }
            return try OfficialUpdateProcess.command(launcher: launcher, steam: steam).run(action, cancellation: cancellation)
        }, status: status)
        guard !cancellation.isCancelled else { throw ClientUpdateError.message("KCD:MP update cancelled.") }
        guard FileManager.default.fileExists(atPath: game.appendingPathComponent("ui/launcher.html").path) else {
            throw PlacementError.message("The multiplayer UI is missing. Keep all files from the official multiplayer ZIP together.")
        }
        try verifyGameNotRunning(launcherPath: launcher.path)
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/KCD2MP Mac/" + UUID().uuidString)
        let arguments = ["KCD2MP Mac", "--steam-launcher", launcher.path, "--exe", launcher.path,
                         "--allowed-root", game.appendingPathComponent("ui").path, "--log-directory", logs.path, "--allow-join",
                         "--cef-helper", helper.path, "--cef-loader", runtime.appendingPathComponent("kcdmp_compat_loader.exe").path,
                         "--cef-watcher", runtime.appendingPathComponent("kcdmp_compat_watcher.exe").path,
                         "--cef-client-sha256", target.client_sha256]
        let config = try BridgeConfiguration(arguments: arguments)
        let placement = try LoaderPlacement(directory: game, loader: bridge, expectedHash: target.bridge_sha256, lease: lease)
        return PackagedLauncher(configuration: config, placement: placement)
    }
}
