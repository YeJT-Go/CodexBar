import Foundation

protocol UsageStoring: Sendable {
    func load() -> UsageSnapshot?
    func save(_ value: UsageSnapshot)
}

final class UsageStore: UsageStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "codexBar.usageSnapshot") {
        self.defaults = defaults
        self.key = key
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func load() -> UsageSnapshot? {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? decoder.decode(UsageSnapshot.self, from: data)
        }
    }

    func save(_ value: UsageSnapshot) {
        lock.withLock {
            guard let data = try? encoder.encode(value) else { return }
            defaults.set(data, forKey: key)
        }
    }
}
