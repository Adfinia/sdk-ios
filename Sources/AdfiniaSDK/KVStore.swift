// Thin key-value abstraction so the SDK can swap UserDefaults (production)
// for an in-memory dictionary (tests, watchOS extensions running before
// the defaults backend is hooked up). Mirrors `sdks/web/src/storage.ts`.

import Foundation

/// Minimal key-value protocol the SDK uses for identity + queue persistence.
public protocol AdfiniaKVStore {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func remove(forKey key: String)
}

/// UserDefaults-backed implementation. The SDK uses a dedicated suite
/// (`com.adfinia.sdk`) so it never collides with the host app's settings
/// and the host app can wipe SDK state without touching its own.
final class UserDefaultsStore: AdfiniaKVStore {
    private let defaults: UserDefaults

    init(suiteName: String) {
        // `UserDefaults(suiteName:)` returns nil only for reserved names
        // (`NSGlobalDomain`, `NSArgumentDomain`, the bundle id). For any
        // other name it always returns a valid container.
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func remove(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory KV store. Used as a fallback in test sandboxes and when the
/// caller explicitly opts out of persistence.
public final class InMemoryStore: AdfiniaKVStore {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func set(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }

    public func remove(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: key)
    }
}
