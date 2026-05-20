// Identity ledger. Owns the anonymous_id + customer_id + traits triple
// and is the single place that persists them. Mirrors
// `sdks/web/src/identity.ts`.
//
// Persistence is via the injected ``AdfiniaKVStore`` — defaults to a
// UserDefaults suite named `com.adfinia.sdk` in production builds.

import Foundation

/// Identity slice persisted across cold-starts.
struct AdfiniaIdentity: Codable, Equatable {
    var anonymousId: String
    var customerId: String?
    var traits: [String: AdfiniaJSONValue]?

    enum CodingKeys: String, CodingKey {
        case anonymousId = "anonymous_id"
        case customerId = "customer_id"
        case traits
    }
}

final class IdentityStore {
    static let storageKey = "adfinia.identity"

    private let store: AdfiniaKVStore
    private var state: AdfiniaIdentity
    private let lock = NSLock()

    init(store: AdfiniaKVStore) {
        self.store = store
        self.state = Self.load(from: store) ?? AdfiniaIdentity(anonymousId: UUIDv7.generate())
        // Eagerly persist the freshly-minted anonymous id so a crash
        // before the first event still leaves a stable identity.
        Self.persist(state, to: store)
    }

    private static func load(from store: AdfiniaKVStore) -> AdfiniaIdentity? {
        guard let raw = store.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AdfiniaIdentity.self, from: data),
              !parsed.anonymousId.isEmpty
        else { return nil }
        return parsed
    }

    private static func persist(_ state: AdfiniaIdentity, to store: AdfiniaKVStore) {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8)
        else { return }
        store.set(json, forKey: storageKey)
    }

    var anonymousId: String {
        lock.lock(); defer { lock.unlock() }
        return state.anonymousId
    }

    var customerId: String? {
        lock.lock(); defer { lock.unlock() }
        return state.customerId
    }

    var traits: [String: AdfiniaJSONValue]? {
        lock.lock(); defer { lock.unlock() }
        return state.traits
    }

    func identify(customerId: String?, traits: [String: AdfiniaJSONValue]?, anonymousId: String?) {
        lock.lock()
        if let anonymousId = anonymousId { state.anonymousId = anonymousId }
        if let customerId = customerId { state.customerId = customerId }
        if let traits = traits {
            var merged = state.traits ?? [:]
            for (k, v) in traits { merged[k] = v }
            state.traits = merged
        }
        let snapshot = state
        lock.unlock()
        Self.persist(snapshot, to: store)
    }

    /// Stash a server-resolved customer id (returned from `/api/v1/identify`).
    /// Does not touch traits or anonymous_id.
    func setResolvedCustomerId(_ id: String) {
        lock.lock()
        state.customerId = id
        let snapshot = state
        lock.unlock()
        Self.persist(snapshot, to: store)
    }

    /// Clear customer_id + traits and mint a new anonymous_id. Used on logout.
    func reset() {
        lock.lock()
        state = AdfiniaIdentity(anonymousId: UUIDv7.generate())
        let snapshot = state
        lock.unlock()
        Self.persist(snapshot, to: store)
    }
}
