// IdentityStore — anonymous_id + customer_id + traits.
// Skeleton: in-memory only. NEXT-IOS-3 wires this to UserDefaults so the
// identity persists across cold-starts.

import Foundation

final class IdentityStore {
    private(set) var anonymousId: String
    private(set) var customerId: String?
    private(set) var traits: AdfiniaTraits?

    init() {
        // TODO NEXT-IOS-3: load from UserDefaults suite "com.adfinia.sdk".
        self.anonymousId = UUID().uuidString
    }

    func identify(customerId: String?, traits: AdfiniaTraits?, anonymousId: String?) {
        if let anonymousId = anonymousId { self.anonymousId = anonymousId }
        if let customerId = customerId { self.customerId = customerId }
        if let traits = traits {
            if var current = self.traits {
                for (k, v) in traits { current[k] = v }
                self.traits = current
            } else {
                self.traits = traits
            }
        }
        // TODO NEXT-IOS-3: persist().
    }

    func reset() {
        self.anonymousId = UUID().uuidString
        self.customerId = nil
        self.traits = nil
        // TODO NEXT-IOS-3: persist().
    }
}
