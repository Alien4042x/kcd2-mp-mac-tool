import SwiftUI
import Foundation
import AppKit

struct MPServer: Decodable, Identifiable {
    let address: String
    let port: Int
    let name: String
    let level: String
    let players: Int
    let maxPlayers: Int
    let gamemode: String
    let version: String
    let passworded: Bool

    var id: String { "\(address):\(port)" }
    var region: String {
        switch level {
        case "kutnohorsko": return "Kuttenberg"
        case "trosecko": return "Trosky"
        case "klaster": return "Monastery"
        default: return level
        }
    }
}

enum LaunchError: LocalizedError {
    case missingHelper
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingHelper: return "The Wine launch helper is missing from the app."
        case .badResponse: return "KCD:MP returned an invalid server-list response."
        }
    }
}

func helperURL() throws -> URL {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("kcdmp-launch.sh"),
          FileManager.default.fileExists(atPath: url.path) else { throw LaunchError.missingHelper }
    return url
}

@MainActor final class LauncherModel: ObservableObject {
    @Published var servers: [MPServer] = []
    @Published var listStatus = "Loading servers…"
    @Published var isRefreshing = false
    @Published var actionStatus = "Select a server and connect."
    @Published var gameRunning = false
    private var gameProcess: Process?
    private var activeCEFLaunchID: UUID?

    func refreshServers() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        listStatus = "Loading servers…"
        do {
            var request = URLRequest(url: URL(string: "https://kcd-mp.com/server-list/servers")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LaunchError.badResponse
            }
            servers = try JSONDecoder().decode([MPServer].self, from: data)
            listStatus = "\(servers.count) servers • refreshed just now"
        } catch {
            listStatus = servers.isEmpty
                ? "Could not load servers: \(error.localizedDescription)"
                : "Could not refresh. Showing last known player counts: \(error.localizedDescription)"
        }
    }

    func join(address: String, name: String, password: String, launcherPath: String) {
        guard !gameRunning else { return }
        do {
            let steamEnvironment = try environmentForRunningSteam(launcherPath: launcherPath)
            guard let bottleRange = launcherPath.range(of: "/drive_c/") else {
                throw SteamProcessError.notRunning
            }
            let bottle = String(launcherPath[..<bottleRange.lowerBound])
            if FileManager.default.fileExists(atPath: bottle + "/cxbottle.conf") {
                try joinThroughCrossOver(address: address, name: name, password: password,
                                         launcherPath: launcherPath, steamEnvironment: steamEnvironment)
            } else {
                guard let resources = Bundle.main.resourceURL else { throw LaunchError.missingHelper }
                let launchID = UUID()
                activeCEFLaunchID = launchID
                gameRunning = true
                actionStatus = "Checking KCD:MP compatibility…"
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    do {
                        try CEFLauncher.run(launcherPath: launcherPath, address: address, name: name,
                                            password: password, steamEnvironment: steamEnvironment,
                                            resourceURL: resources) { message in
                            Task { @MainActor [weak self] in
                                guard self?.activeCEFLaunchID == launchID else { return }
                                self?.actionStatus = message
                            }
                        }
                        Task { @MainActor [weak self] in
                            guard self?.activeCEFLaunchID == launchID else { return }
                            self?.activeCEFLaunchID = nil
                            self?.gameRunning = false
                            self?.actionStatus = "Game closed."
                        }
                    } catch {
                        Task { @MainActor [weak self] in
                            guard self?.activeCEFLaunchID == launchID else { return }
                            self?.activeCEFLaunchID = nil
                            self?.gameRunning = false
                            self?.actionStatus = "Launch failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        } catch {
            actionStatus = "Launch failed: \(error.localizedDescription)"
        }
    }

    private func joinThroughCrossOver(address: String, name: String, password: String,
                                      launcherPath: String, steamEnvironment: [String: String]) throws {
        let helper = try helperURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helper.path, "--launcher", launcherPath, "--launch", address, name]
            + (password.isEmpty ? [] : [password])
        var environment = ProcessInfo.processInfo.environment
        environment.merge(steamEnvironment) { _, steamValue in steamValue }
        environment.removeValue(forKey: "WINELOADERNOEXEC")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        gameProcess = process
        gameRunning = true
        actionStatus = "Connecting through CrossOver…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var tail = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
                if tail.count > 16_384 { tail.removeFirst(tail.count - 16_384) }
            }
            process.waitUntilExit()
            let lastLine = String(decoding: tail, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)
            Task { @MainActor in
                self?.gameRunning = false
                self?.gameProcess = nil
                self?.actionStatus = process.terminationStatus == 0
                    ? "Game closed."
                    : (lastLine ?? "Launch failed with code \(process.terminationStatus).")
            }
        }
    }
}

struct ServerRow: View {
    let server: MPServer
    let isOlderVersion: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.name).font(.system(size: 14, weight: .semibold))
                    if server.passworded { Image(systemName: "lock.fill").font(.caption) }
                }
                Text("\(server.gamemode) • \(server.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(server.region).frame(width: 95, alignment: .leading)
            Text("\(server.players)/\(server.maxPlayers)").frame(width: 60, alignment: .trailing)
            Text(server.version)
                .foregroundStyle(isOlderVersion ? Color.orange : Color.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

struct ContentView: View {
    @StateObject private var model = LauncherModel()
    @AppStorage("KCDMPPlayerName") private var nickname = ""
    @AppStorage("KCDMPLauncherPath") private var launcherPath = "~/WineForge/Steam/drive_c/Program Files (x86)/Steam/steamapps/Common/KingdomComeDeliverance2/Bin/Win64MasterMasterSteamPGO/KcdMp_launcher.exe"
    @State private var serverPassword = ""
    @State private var directAddress = ""
    @State private var selectedID: String?

    private var expandedLauncherPath: String { (launcherPath as NSString).expandingTildeInPath }
    private var bottlePrefix: String? {
        guard let range = expandedLauncherPath.range(of: "/drive_c/") else { return nil }
        return String(expandedLauncherPath[..<range.lowerBound])
    }
    private var launcherReady: Bool {
        var isDirectory: ObjCBool = false
        return URL(fileURLWithPath: expandedLauncherPath).lastPathComponent == "KcdMp_launcher.exe"
            && FileManager.default.fileExists(atPath: expandedLauncherPath, isDirectory: &isDirectory)
            && !isDirectory.boolValue && bottlePrefix != nil
    }
    private var newestServerVersion: String {
        model.servers.map(\.version).max {
            $0.compare($1, options: .numeric) == .orderedAscending
        } ?? ""
    }
    private var selectedServer: MPServer? { model.servers.first { $0.id == selectedID } }
    private var targetAddress: String {
        let direct = directAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return direct.isEmpty ? (selectedServer?.id ?? "") : direct
    }
    private var needsServerPassword: Bool {
        !directAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedServer?.passworded == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("KCD:MP for Mac").font(.system(size: 28, weight: .bold, design: .rounded))

            HStack {
                Text("KCD:MP file")
                Text(launcherReady ? "Ready" : "Choose KcdMp_launcher.exe")
                    .foregroundStyle(launcherReady ? Color.secondary : Color.orange)
                Spacer()
                Button("Change…") { chooseLauncher() }
            }
            .help(expandedLauncherPath)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nickname").font(.caption).foregroundStyle(.secondary)
                    TextField("Your in-game name", text: $nickname)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server password").font(.caption).foregroundStyle(.secondary)
                    SecureField("For locked servers only", text: $serverPassword)
                        .disabled(!needsServerPassword)
                }
            }

            HStack {
                Text(model.listStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.refreshServers() } }
                    .disabled(model.isRefreshing)
            }
            List(selection: $selectedID) {
                ForEach(model.servers) { server in
                    ServerRow(server: server,
                              isOlderVersion: server.version.compare(newestServerVersion, options: .numeric) == .orderedAscending)
                        .tag(server.id)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)

            HStack(spacing: 12) {
                Text("Direct address").font(.caption).foregroundStyle(.secondary)
                TextField("host:port (optional)", text: $directAddress)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") { joinSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.gameRunning)
            }

            Text(model.actionStatus).font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 790, minHeight: 520)
        .task {
            migrateLauncherPath()
            await model.refreshServers()
        }
    }

    private func chooseLauncher() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: expandedLauncherPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let chosen = panel.url {
            launcherPath = chosen.path
        }
    }

    private func migrateLauncherPath() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "KCDMPLauncherPath") == nil else { return }
        if let old = defaults.string(forKey: "KCDMPWineForgeLauncher"), !old.isEmpty {
            launcherPath = old
        } else if let oldPrefix = defaults.string(forKey: "KCDMPWineForgePrefix"), !oldPrefix.isEmpty {
            launcherPath = oldPrefix + "/drive_c/Program Files (x86)/Steam/steamapps/Common/KingdomComeDeliverance2/Bin/Win64MasterMasterSteamPGO/KcdMp_launcher.exe"
        }
    }

    private func joinSelected() {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            model.actionStatus = "Enter your nickname first."
            return
        }
        guard launcherReady else {
            model.actionStatus = "Choose KcdMp_launcher.exe inside your Wine bottle."
            return
        }
        let address = targetAddress
        guard address.range(of: #"^[A-Za-z0-9.-]+:[0-9]{1,5}$"#, options: .regularExpression) != nil,
              let port = Int(address.split(separator: ":").last ?? ""), (1...65535).contains(port) else {
            model.actionStatus = "Select a server or enter an address as host:port."
            return
        }
        if selectedServer?.passworded == true && directAddress.isEmpty && serverPassword.isEmpty {
            model.actionStatus = "This server requires a server password."
            return
        }
        let token = needsServerPassword ? serverPassword : ""
        model.join(address: address, name: name, password: token, launcherPath: expandedLauncherPath)
        serverPassword = ""
    }
}

@main struct KCDMPMacApp: App {
    init() {
        // The Xcode project uses a fresh bundle ID so macOS refreshes the app icon.
        // Keep the nickname and selected MP path from earlier local builds.
        if let previous = UserDefaults(suiteName: "local.kcdmp.maclauncher") {
            for key in ["KCDMPPlayerName", "KCDMPLauncherPath",
                        "KCDMPWineForgeLauncher", "KCDMPWineForgePrefix"] {
                if UserDefaults.standard.object(forKey: key) == nil,
                   let value = previous.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
