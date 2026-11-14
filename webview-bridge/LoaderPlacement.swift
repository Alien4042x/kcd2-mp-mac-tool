import Foundation
import CryptoKit
import Darwin

enum PlacementError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func fileSHA256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

// Own only the DLL created by this app. Existing or replaced files are preserved.
final class LoaderPlacement {
    private struct Receipt: Codable {
        let sha256: String
        let inode: UInt64
        let device: Int32
    }
    private let target: URL
    private let receiptURL: URL
    private var lockFD: Int32 = -1
    private var receipt: Receipt?

    init(directory: URL, loader: URL, expectedHash: String) throws {
        target = directory.appendingPathComponent("WebView2Loader.dll")
        receiptURL = directory.appendingPathComponent(".kcd2mp-webview-loader.json")
        let lockURL = directory.appendingPathComponent(".kcd2mp-webview-loader.lock")
        lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw PlacementError.message("Cannot open the launcher session lock.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            lockFD = -1
            throw PlacementError.message("KCD2MP Mac is already using this multiplayer folder.")
        }
        do {
            let data = try Data(contentsOf: loader)
            guard data.starts(with: [0x4d, 0x5a]), try fileSHA256(loader) == expectedHash else {
                throw PlacementError.message("The bundled WebKit bridge is damaged.")
            }
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                let previous = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
                try removeOwned(previous)
                try FileManager.default.removeItem(at: receiptURL)
            }
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw PlacementError.message("A WebView2Loader.dll already exists here. It has been left unchanged.") }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var identity = stat()
            guard fstat(fd, &identity) == 0 else {
                try? output.close()
                throw PlacementError.message("Cannot identify the temporary WebKit bridge.")
            }
            let owned = Receipt(sha256: expectedHash, inode: identity.st_ino, device: identity.st_dev)
            do {
                try output.write(contentsOf: data)
                try output.synchronize()
                try output.close()
                guard try fileSHA256(target) == expectedHash else { throw PlacementError.message("Temporary bridge verification failed.") }
                try JSONEncoder().encode(owned).write(to: receiptURL, options: .atomic)
                receipt = owned
            } catch {
                // A partial write still belongs to this exact inode.
                var current = stat()
                if lstat(target.path, &current) == 0 && current.st_ino == owned.inode && current.st_dev == owned.device {
                    try? FileManager.default.removeItem(at: target)
                }
                throw error
            }
        } catch {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
            throw error
        }
    }

    private func removeOwned(_ owned: Receipt) throws {
        var current = stat()
        guard lstat(target.path, &current) == 0 else {
            if errno == ENOENT { return }
            throw PlacementError.message("Cannot inspect the temporary WebKit bridge.")
        }
        guard current.st_mode & S_IFMT == S_IFREG, current.st_ino == owned.inode,
              current.st_dev == owned.device, try fileSHA256(target) == owned.sha256 else {
            throw PlacementError.message("The temporary bridge was changed by another program. It has been left unchanged.")
        }
        try FileManager.default.removeItem(at: target)
    }

    func cleanup() throws {
        guard let owned = receipt else { return }
        try removeOwned(owned)
        try FileManager.default.removeItem(at: receiptURL)
        receipt = nil
    }

    deinit {
        try? cleanup()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
}
