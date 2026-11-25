import Foundation
import Darwin

@main
struct PlacementTests {
    static func check(_ expression: @autoclosure () throws -> Bool) throws {
        let result = try expression()
        precondition(result)
    }
    static func requireFailure(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        precondition(failed, "Expected a rejected placement")
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--leave" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let loader = directory.appendingPathComponent("bundled.dll")
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: fileSHA256(loader))
            withExtendedLifetime(placement) { _exit(0) }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kcd2mp-placement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var cases = 0
        func fixture(_ body: (URL, URL, String) throws -> Void) throws {
            cases += 1
            let directory = scratch.appendingPathComponent(String(cases))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let loader = directory.appendingPathComponent("bundled.dll")
            try Data("MZ fixture bridge".utf8).write(to: loader)
            try body(directory, loader, fileSHA256(loader))
        }
        try fixture { directory, loader, digest in
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest)
            let target = directory.appendingPathComponent("WebView2Loader.dll")
            try check(try fileSHA256(target) == digest)
            try requireFailure { _ = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest) }
            try placement.cleanup()
            precondition(!FileManager.default.fileExists(atPath: target.path))
            try placement.cleanup()
        }
        try fixture { directory, loader, digest in
            let target = directory.appendingPathComponent("WebView2Loader.dll")
            try Data("existing".utf8).write(to: target)
            try requireFailure { _ = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest) }
            try check(try Data(contentsOf: target) == Data("existing".utf8))
        }
        try fixture { directory, loader, digest in
            try requireFailure { _ = try LoaderPlacement(directory: directory, loader: loader, expectedHash: String(repeating: "0", count: 64)) }
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest)
            try placement.cleanup()
        }
        try fixture { directory, loader, digest in
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest)
            let target = directory.appendingPathComponent("WebView2Loader.dll")
            try Data("replacement".utf8).write(to: target, options: .atomic)
            try requireFailure { try placement.cleanup() }
            try check(try Data(contentsOf: target) == Data("replacement".utf8))
        }
        try fixture { directory, loader, digest in
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("WebView2Loader.dll"))
            try placement.cleanup()
        }
        try fixture { directory, loader, digest in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--leave", directory.path]
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest)
            try placement.cleanup()
            precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("WebView2Loader.dll").path))
        }
        try fixture { directory, loader, digest in
            let target = directory.appendingPathComponent("WebView2Loader.dll")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: loader)
            try requireFailure { _ = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest) }
            try check(try fileSHA256(loader) == digest)
        }
        try fixture { directory, loader, digest in
            let lease = try LauncherFolderLease(directory: directory)
            try requireFailure { _ = try LauncherFolderLease(directory: directory) }
            try requireFailure { _ = try LoaderPlacement(directory: directory, loader: loader, expectedHash: "invalid", lease: lease) }
            try requireFailure { _ = try LauncherFolderLease(directory: directory) }
            let placement = try LoaderPlacement(directory: directory, loader: loader, expectedHash: digest, lease: lease)
            try placement.cleanup()
            try requireFailure { _ = try LauncherFolderLease(directory: directory) }
        }
        try fixture { directory, loader, digest in
            let other = directory.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let lease = try LauncherFolderLease(directory: directory)
            try requireFailure { _ = try LoaderPlacement(directory: other, loader: loader, expectedHash: digest, lease: lease) }
            precondition(!FileManager.default.fileExists(atPath: other.appendingPathComponent("WebView2Loader.dll").path))
        }
        print("Loader placement checks passed: \(cases) cases, including lock contention, failed init, replacement and interrupted-session recovery")
    }
}
