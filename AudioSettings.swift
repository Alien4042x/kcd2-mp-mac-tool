import SwiftUI
import AVFoundation
import CoreAudio
import AppKit
import Darwin

struct SystemAudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

enum AudioSettingsError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noInput

    var errorDescription: String? {
        switch self {
        case .coreAudio(let action, let status): return "\(action) failed (Core Audio \(status))."
        case .noInput: return "No usable microphone is available. Connect an input device and refresh."
        }
    }
}

@MainActor final class AudioSettingsModel: ObservableObject {
    @Published private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var requesting = false
    @Published private(set) var inputs: [SystemAudioDevice] = []
    @Published private(set) var outputs: [SystemAudioDevice] = []
    @Published private(set) var inputID = kAudioObjectUnknown
    @Published private(set) var outputID = kAudioObjectUnknown
    @Published private(set) var testing = false
    @Published private(set) var wineTesting = false
    @Published private(set) var level: Double = 0
    @Published var message = ""
    private var engine: AVAudioEngine?
    private var testID: UUID?

    var permissionText: String {
        switch authorization {
        case .authorized: return "Allowed in macOS"
        case .notDetermined: return "Not requested yet"
        case .denied: return "Disabled in macOS"
        case .restricted: return "Restricted by macOS"
        @unknown default: return "Unknown permission state"
        }
    }

    func refreshPermission() { authorization = AVCaptureDevice.authorizationStatus(for: .audio) }

    func requestAccess() async {
        guard !requesting else { return }
        refreshPermission()
        guard authorization == .notDetermined else { return }
        requesting = true
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshPermission()
        requesting = false
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        guard status == noErr else { throw AudioSettingsError.coreAudio("Reading the default device", status) }
        return device
    }

    private func deviceName(_ id: AudioDeviceID) throws -> String {
        var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &name)
        guard status == noErr, let name else {
            throw AudioSettingsError.coreAudio("Reading an audio device name", status == noErr ? kAudioHardwareUnspecifiedError : status)
        }
        return name.takeRetainedValue() as String
    }

    private func hasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Bool {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size)
        guard status == noErr else { throw AudioSettingsError.coreAudio("Reading audio streams", status) }
        return size > 0
    }

    func refreshDevices() {
        refreshPermission()
        do {
            var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size)
            guard status == noErr else { throw AudioSettingsError.coreAudio("Listing audio devices", status) }
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            if !ids.isEmpty {
                status = ids.withUnsafeMutableBytes {
                    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
                }
                guard status == noErr else { throw AudioSettingsError.coreAudio("Reading audio devices", status) }
                ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
            }
            var newInputs: [SystemAudioDevice] = []
            var newOutputs: [SystemAudioDevice] = []
            for id in ids {
                let device = SystemAudioDevice(id: id, name: try deviceName(id))
                if try hasChannels(id, scope: kAudioDevicePropertyScopeInput) { newInputs.append(device) }
                if try hasChannels(id, scope: kAudioDevicePropertyScopeOutput) { newOutputs.append(device) }
            }
            let newInputID = try defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
            let newOutputID = try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            inputs = newInputs
            outputs = newOutputs
            inputID = newInputID
            outputID = newOutputID
            message = ""
        } catch {
            inputs = []
            outputs = []
            inputID = kAudioObjectUnknown
            outputID = kAudioObjectUnknown
            message = error.localizedDescription
        }
    }

    func selectDevice(_ id: AudioDeviceID, input: Bool) {
        stopTest()
        guard (input ? inputs : outputs).contains(where: { $0.id == id }) else { return }
        var property = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var selected = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &selected)
        guard status == noErr else {
            message = AudioSettingsError.coreAudio("Changing the default device", status).localizedDescription
            return
        }
        refreshDevices()
    }

    func startTest() async {
        guard !testing, !requesting else { return }
        await requestAccess()
        guard authorization == .authorized else {
            message = "Allow microphone access in macOS before testing."
            return
        }
        do {
            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioSettingsError.noInput }
            let session = UUID()
            testID = session
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
                var peak: Float = 0
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[0][index])) }
                let measured = Double(min(1, max(0, (20 * log10(max(peak, 0.000001)) + 60) / 60)))
                Task { @MainActor [weak self] in
                    guard self?.testID == session else { return }
                    self?.level = measured
                }
            }
            engine = audioEngine
            try audioEngine.start()
            testing = true
            message = "Speak to check the meter. This Mac-only test stops after 10 seconds. No audio is saved or sent."
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard self?.testID == session else { return }
                self?.stopTest()
            }
        } catch {
            stopTest()
            message = "Microphone test failed: \(error.localizedDescription)"
        }
    }

    func stopTest() {
        testID = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        testing = false
        level = 0
    }

    func testWineInput(launcherPath: String) async {
        guard !wineTesting, !requesting else { return }
        stopTest()
        await requestAccess()
        guard authorization == .authorized else {
            message = "Allow microphone access in macOS before testing Wine input."
            return
        }
        wineTesting = true
        defer { wineTesting = false }
        message = "Testing one second of microphone input through Wine. No audio is saved or sent."
        do {
            let steamEnvironment = try environmentForRunningSteam(launcherPath: launcherPath)
            try verifyRunningWineServer(environment: steamEnvironment)
            let wine = steamEnvironment["WINE"] ?? steamEnvironment["CX_ROOT"].map { $0 + "/bin/wine" }
            guard let wine, let probe = Bundle.main.url(forResource: "microphone_probe", withExtension: "exe"),
                  FileManager.default.isExecutableFile(atPath: wine),
                  FileManager.default.fileExists(atPath: probe.path) else {
                throw CEFLaunchError.message("The Wine microphone test helper or selected Wine runtime is missing.")
            }
            var environment = ProcessInfo.processInfo.environment
            environment.merge(steamEnvironment) { _, steamValue in steamValue }
            environment.removeValue(forKey: "WINELOADERNOEXEC")
            let result = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: wine)
                process.arguments = [probe.path]
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    process.terminate()
                    let stopDeadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < stopDeadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    throw CEFLaunchError.message("Wine microphone test timed out. Check for a macOS permission dialog.")
                }
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let report = try JSONDecoder().decode(WineInputReport.self, from: data)
                return try report.summary(exitCode: process.terminationStatus)
            }.value
            message = result
        } catch {
            message = "Wine microphone test could not be completed: \(error.localizedDescription)"
        }
    }

    func openWineSettings(launcherPath: String) {
        do {
            let steamEnvironment = try environmentForRunningSteam(launcherPath: launcherPath)
            try verifyRunningWineServer(environment: steamEnvironment)
            let wine = steamEnvironment["WINE"] ?? steamEnvironment["CX_ROOT"].map { $0 + "/bin/wine" }
            guard let wine, FileManager.default.isExecutableFile(atPath: wine) else {
                throw SteamProcessError.notRunning
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: wine)
            process.arguments = ["winecfg.exe"]
            var environment = ProcessInfo.processInfo.environment
            environment.merge(steamEnvironment) { _, steamValue in steamValue }
            environment.removeValue(forKey: "WINELOADERNOEXEC")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] completed in
                guard completed.terminationStatus != 0 else { return }
                Task { @MainActor [weak self] in
                    self?.message = "Wine audio settings exited with code \(completed.terminationStatus)."
                }
            }
            try process.run()
            message = "Opening Wine configuration in the selected Steam session. Select its Audio tab to inspect input and voice devices."
        } catch {
            message = "Could not open Wine audio settings: \(error.localizedDescription)"
        }
    }
}

struct AudioSettingsView: View {
    @ObservedObject var model: AudioSettingsModel
    let launcherPath: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio & Microphone").font(.title2.bold())
            HStack {
                Text("Microphone: \(model.permissionText)")
                Spacer()
                if model.authorization == .notDetermined {
                    Button("Allow Microphone…") { Task { await model.requestAccess() } }
                        .disabled(model.requesting)
                } else {
                    Button("Privacy Settings…") { model.openPrivacySettings() }
                }
            }
            GroupBox("Mac default audio devices") {
                VStack(alignment: .leading, spacing: 12) {
                    devicePicker("Input", devices: model.inputs, selected: model.inputID, input: true)
                    devicePicker("Output", devices: model.outputs, selected: model.outputID, input: false)
                    Text("Changing these devices changes the Mac defaults for all apps. Wine can also use a device selected in its own audio settings. Reopen the game if it keeps using the previous device.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Button(model.testing ? "Stop Test" : "Test Microphone") {
                    if model.testing { model.stopTest() } else { Task { await model.startTest() } }
                }.disabled(model.requesting || model.wineTesting)
                ProgressView(value: model.level).frame(width: 220)
                    .accessibilityLabel("Microphone input level")
                Spacer()
                Button("Refresh Devices") { model.stopTest(); model.refreshDevices() }
            }
            Text(model.message.isEmpty ? "The meter tests Mac audio input. Voice chat in Wine needs a separate in-game check." : model.message)
                .font(.caption).foregroundStyle(.secondary).frame(minHeight: 35, alignment: .topLeading)
            HStack {
                Button(model.wineTesting ? "Testing Wine…" : "Test Wine Input") {
                    Task { await model.testWineInput(launcherPath: launcherPath) }
                }.disabled(model.wineTesting || model.requesting)
                Button("Wine Audio Settings…") { model.openWineSettings(launcherPath: launcherPath) }
                Button("macOS Sound…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 590)
        .onAppear { model.refreshDevices() }
        .onDisappear { model.stopTest() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.stopTest(); model.refreshDevices() }
        }
    }

    private func devicePicker(_ title: String, devices: [SystemAudioDevice], selected: AudioDeviceID,
                              input: Bool) -> some View {
        Picker(title, selection: Binding(get: { selected }, set: { model.selectDevice($0, input: input) })) {
            if !devices.contains(where: { $0.id == selected }) {
                Text("No default device").tag(selected)
            }
            ForEach(devices) { device in Text(device.name).tag(device.id) }
        }.disabled(devices.isEmpty || model.testing)
    }
}
