import AppKit
import Darwin

final class Fixture: NSObject, NSApplicationDelegate {
    let report: URL
    let appWasPrecreated: Bool
    var first: Int?
    init(report: URL, appWasPrecreated: Bool) { self.report = report; self.appWasPrecreated = appWasPrecreated }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in self.first = NSApp.activationPolicy().rawValue }
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in NSApp.setActivationPolicy(.regular) }
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            do {
                let record: [String: Any] = ["first": self.first ?? -1, "after_repromotion": NSApp.activationPolicy().rawValue,
                                           "app_was_precreated": self.appWasPrecreated,
                                           "preload_leaked": getenv("DYLD_INSERT_LIBRARIES") != nil]
                try JSONSerialization.data(withJSONObject: record).write(to: self.report)
                exit(0)
            } catch { exit(2) }
        }
    }
}

@main
struct DockPolicyFixture {
    static func main() {
        guard let report = CommandLine.arguments.last, CommandLine.arguments.count >= 3 else { exit(2) }
        if CommandLine.arguments.contains("--reexec"), getenv("KCDMP_DOCK_FIXTURE_STAGE") == nil {
            setenv("KCDMP_DOCK_FIXTURE_STAGE", "2", 1)
            execv(CommandLine.arguments[0], CommandLine.unsafeArgv)
            exit(2)
        }
        let precreated = NSApp != nil
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Fixture(report: URL(fileURLWithPath: report), appWasPrecreated: precreated)
        app.delegate = delegate
        // Reproduce Wine's nested Cocoa loop rather than a normal app main.
        var context = CFRunLoopSourceContext()
        context.perform = { _ in NSApp.run() }
        let source = CFRunLoopSourceCreate(nil, 0, &context)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CFRunLoopSourceSignal(source)
        withExtendedLifetime(delegate) { CFRunLoopRun() }
    }
}
