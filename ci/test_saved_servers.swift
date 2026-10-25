import Foundation

@main struct SavedServersChecks {
    @MainActor static func main() throws {
        let suite = "com.kcdmp.tests.saved-servers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedServers(defaults: defaults)
        precondition(store.favorites.isEmpty && store.recent.isEmpty && store.storageError == nil)
        for invalid in ["", "server", "host:0", "host:65536", "host:-1", "host:abc", "host:1/path"] {
            precondition(!validServerAddress(invalid))
            store.remember(address: invalid, name: "Invalid")
            store.toggleFavorite(address: invalid, name: "Invalid")
        }
        precondition(store.favorites.isEmpty && store.recent.isEmpty)
        store.toggleFavorite(address: "127.0.0.1:27877", name: "Local server")
        precondition(store.isFavorite("127.0.0.1:27877"))
        precondition(SavedServers(defaults: defaults).favorites == store.favorites)
        store.toggleFavorite(address: "127.0.0.1:27877", name: "Local server")
        precondition(!store.isFavorite("127.0.0.1:27877"))
        for port in 1...12 { store.remember(address: "example.com:\(port)", name: "Server \(port)") }
        precondition(store.recent.count == 10 && store.recent.first?.address == "example.com:12")
        store.remember(address: "example.com:5", name: "Renamed server")
        precondition(store.recent.count == 10 && store.recent.first?.name == "Renamed server")
        precondition(Set(store.recent.map(\.address)).count == 10)
        precondition(SavedServers(defaults: defaults).recent == store.recent)
        for corrupt: Any in ["wrong type", Data("null".utf8), Data("{}".utf8), Data("not json".utf8),
                             Data(#"[{"address":"host:0","name":"bad"}]"#.utf8),
                             Data(#"[{"address":"host:1"}]"#.utf8),
                             Data(#"[{"address":"host:1","name":"A"},{"address":"host:1","name":"B"}]"#.utf8)] {
            defaults.set(corrupt, forKey: "KCDMPFavoriteServers")
            let broken = SavedServers(defaults: defaults)
            precondition(broken.storageError != nil)
            broken.toggleFavorite(address: "localhost:1234", name: "New")
            precondition(broken.favorites.isEmpty)
            precondition(NSDictionary(dictionary: ["value": defaults.object(forKey: "KCDMPFavoriteServers")!])
                .isEqual(to: ["value": corrupt]))
        }
        print("PASS: address validation, favorites persistence, recent deduplication and limit, malformed data preserved")
    }
}
