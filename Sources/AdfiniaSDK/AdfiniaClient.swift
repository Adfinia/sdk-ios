// AdfiniaClient — internal coordinator. The Adfinia enum's static surface
// delegates to a singleton instance of this class. Advanced consumers can
// create their own instance for multi-tenant SSR / test isolation.
//
// Skeleton: in-memory only. NEXT.md tracks the real-transport,
// UserDefaults-persistence, exponential-backoff work.

import Foundation

public final class AdfiniaClient {
    private var config: AdfiniaConfig?
    private var identityStore = IdentityStore()
    private var queue: [AdfiniaPayload] = []
    private let queueLock = NSLock()

    public init() {}

    public func initialize(_ config: AdfiniaConfig) {
        guard self.config == nil else {
            log("init() called twice — ignoring")
            return
        }
        self.config = config
        log("initialised host=\(config.host)")
    }

    public func identify(_ arg: AdfiniaIdentifyArg, traits: AdfiniaTraits? = nil) {
        guard guardCall("identify") else { return }
        var customerId: String?
        var anonymousId: String?
        var mergedTraits: AdfiniaTraits? = traits

        switch arg {
        case .customerId(let id):
            customerId = id
        case .object(let cId, let aId, let t):
            customerId = cId
            anonymousId = aId
            if let t = t { mergedTraits = mergedTraits.map { $0.merging(t) { _, b in b } } ?? t }
        }

        identityStore.identify(customerId: customerId, traits: mergedTraits, anonymousId: anonymousId)
        enqueue(AdfiniaPayload(
            type: .identify,
            event: nil,
            customerId: identityStore.customerId,
            anonymousId: identityStore.anonymousId,
            previousId: nil,
            properties: nil,
            traits: identityStore.traits
        ))
    }

    public func track(_ event: String, properties: AdfiniaProperties? = nil) {
        guard guardCall("track") else { return }
        guard !event.isEmpty else { log("track() without an event — dropped"); return }
        enqueue(AdfiniaPayload(
            type: .track,
            event: event,
            customerId: identityStore.customerId,
            anonymousId: identityStore.anonymousId,
            previousId: nil,
            properties: properties,
            traits: nil
        ))
    }

    public func screen(_ name: String?, properties: AdfiniaProperties?) {
        guard guardCall("screen") else { return }
        enqueue(AdfiniaPayload(
            type: .screen,
            event: name,
            customerId: identityStore.customerId,
            anonymousId: identityStore.anonymousId,
            previousId: nil,
            properties: properties,
            traits: nil
        ))
    }

    public func alias(_ newId: String, previousId: String?) {
        guard guardCall("alias") else { return }
        guard !newId.isEmpty else { return }
        let prev = previousId ?? identityStore.customerId ?? identityStore.anonymousId
        enqueue(AdfiniaPayload(
            type: .alias,
            event: nil,
            customerId: newId,
            anonymousId: identityStore.anonymousId,
            previousId: prev,
            properties: nil,
            traits: nil
        ))
        identityStore.identify(customerId: newId, traits: nil, anonymousId: nil)
    }

    public func reset() {
        guard config != nil else { return }
        identityStore.reset()
    }

    public func flush() async {
        guard config != nil else { return }
        // Skeleton: drain the queue and pretend it shipped. Real transport
        // lands with NEXT-IOS-2.
        queueLock.lock()
        let drained = queue
        queue.removeAll()
        queueLock.unlock()
        log("flushed \(drained.count) event(s) [skeleton — no network]")
    }

    private func enqueue(_ payload: AdfiniaPayload) {
        queueLock.lock()
        queue.append(payload)
        if queue.count > (config?.maxQueueSize ?? 1000) {
            queue.removeFirst()
        }
        queueLock.unlock()
        if queue.count >= (config?.flushAt ?? 50) {
            Task { await flush() }
        }
    }

    private func guardCall(_ label: String) -> Bool {
        guard config != nil else {
            print("[adfinia] \(label)() called before initialize()")
            return false
        }
        if let consent = config?.consent {
            return consent()
        }
        return true
    }

    private func log(_ message: String) {
        guard config?.debug == true else { return }
        print("[adfinia] \(message)")
    }
}

private extension Dictionary {
    func merging(_ other: [Key: Value], uniquingKeysWith: (Value, Value) -> Value) -> [Key: Value] {
        var copy = self
        for (k, v) in other { copy[k] = uniquingKeysWith(copy[k] ?? v, v) }
        return copy
    }
}
