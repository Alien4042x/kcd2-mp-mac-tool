import Foundation
import Combine

struct SavedServer: Codable, Equatable, Identifiable {
    let address: String
    var name: String
    var id: String { address }
}

func validServerAddress(_ address: String) -> Bool {
    guard address.range(of: #"^[A-Za-z0-9.-]+:[0-9]{1,5}$"#, options: .regularExpression) != nil,
          let port = Int(address.split(separator: ":").last ?? "") else { return false }
    return (1...65535).contains(port)
}

@MainActor final class SavedServers: ObservableObject {
    @Published private(set) var favorites: [SavedServer] = []
    @Published private(set) var recent: [SavedServer] = []
    @Published private(set) var storageError: String?
    private let defaults: UserDefaults
    private var unreadableKeys: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = load("KCDMPFavoriteServers")
        recent = load("KCDMPRecentServers")
    }

    private func load(_ key: String) -> [SavedServer] {
        guard let object = defaults.object(forKey: key) else { return [] }
        guard let data = object as? Data,
              let entries = try? JSONDecoder().decode([SavedServer].self, from: data),
              entries.allSatisfy({ validServerAddress($0.address) && !$0.name.isEmpty }),
              Set(entries.map(\.address)).count == entries.count else {
            unreadableKeys.insert(key)
            storageError = "Saved servers could not be read. The original data has been kept."
            return []
        }
        return entries
    }

    private func save(_ entries: [SavedServer], key: String) {
        guard !unreadableKeys.contains(key) else { return }
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: key)
        } catch {
            storageError = "Could not save servers: \(error.localizedDescription)"
        }
    }

    func isFavorite(_ address: String) -> Bool { favorites.contains { $0.address == address } }

    func toggleFavorite(address: String, name: String) {
        guard validServerAddress(address), !unreadableKeys.contains("KCDMPFavoriteServers") else { return }
        if isFavorite(address) {
            favorites.removeAll { $0.address == address }
        } else {
            favorites.append(SavedServer(address: address, name: name.isEmpty ? address : name))
        }
        save(favorites, key: "KCDMPFavoriteServers")
    }

    func remember(address: String, name: String) {
        guard validServerAddress(address), !unreadableKeys.contains("KCDMPRecentServers") else { return }
        recent.removeAll { $0.address == address }
        recent.insert(SavedServer(address: address, name: name.isEmpty ? address : name), at: 0)
        recent = Array(recent.prefix(10))
        save(recent, key: "KCDMPRecentServers")
    }
}
