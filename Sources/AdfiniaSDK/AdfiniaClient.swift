// AdfiniaClient — internal coordinator. The `Adfinia` enum's static
// surface delegates to a singleton instance of this class. Advanced
// consumers (multi-tenant servers, isolated test contexts) can create
// their own instance directly.
//
// Mirrors `sdks/web/src/client.ts`. Behaviour-for-behaviour parity with
// the web SDK is the explicit goal — if you read one, you've read both.

import Foundation

/// Hooks the SDK can use to swap dependencies in tests. Not part of the
/// public surface — exported `internal` only.
struct ClientHooks {
    var transport: Transport?
    var store: AdfiniaKVStore?
    var now: (() -> Date)?
    var loggerOverride: EventQueueDebugLogger?
}

public final class AdfiniaClient {
    private let hooks: ClientHooks
    private let stateLock = NSLock()

    private var config: AdfiniaConfig?
    private var identityStore: IdentityStore?
    private var queue: EventQueue?
    private var transport: Transport?
    private var initialised = false
    private let now: () -> Date

    public convenience init() {
        self.init(hooks: ClientHooks())
    }

    init(hooks: ClientHooks) {
        self.hooks = hooks
        self.now = hooks.now ?? { Date() }
    }

    // MARK: - Public surface

    public func initialize(_ config: AdfiniaConfig) {
        stateLock.lock()
        if initialised {
            log("init() called twice — ignoring")
            stateLock.unlock()
            return
        }
        if config.writeKey.isEmpty {
            stateLock.unlock()
            assertionFailure("AdfiniaSDK: writeKey is required")
            return
        }
        self.config = config
        let store = hooks.store ?? UserDefaultsStore(suiteName: "com.adfinia.sdk")
        let identity = IdentityStore(store: store)
        self.identityStore = identity
        let logger = hooks.loggerOverride ?? PrintDebugLogger(enabled: config.debug)
        let transport = hooks.transport ?? HttpTransport(host: config.host, writeKey: config.writeKey)
        self.transport = transport
        let queueCfg = EventQueueConfig(
            store: store,
            transport: transport,
            flushAt: config.flushAt,
            flushIntervalSeconds: config.flushIntervalSeconds,
            maxQueueSize: config.maxQueueSize,
            logger: logger,
            onResolvedCustomerId: { [weak identity] id in
                identity?.setResolvedCustomerId(id)
            }
        )
        self.queue = EventQueue(config: queueCfg)
        initialised = true
        log("initialised host=\(config.host)")
        stateLock.unlock()

        // Best-effort: pull per-tenant runtime config from the server. The
        // server endpoint (GET /api/v1/sdk/config) returns batch_size /
        // flush_interval_ms / sampling_rate / breaker thresholds; we apply
        // the knobs we understand and ignore the rest. Forward-compat:
        // an older SDK never breaks when the server adds a new field.
        //
        // Detached Task so a slow / failing config fetch never blocks
        // first-event delivery.
        Task.detached { [weak self] in
            await self?.fetchRemoteConfig(host: config.host, writeKey: config.writeKey)
        }
    }

    /// GET /api/v1/sdk/config and apply the knobs we recognise. Soft-fails
    /// on any error — the local defaults stay.
    private func fetchRemoteConfig(host: String, writeKey: String) async {
        let normalisedHost = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard let url = URL(string: normalisedHost + "/api/v1/sdk/config") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AdfiniaVersion.sdkVersionHeader, forHTTPHeaderField: "X-Adfinia-SDK-Version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 426 {
                log("SDK below the server minimum — please upgrade AdfiniaSDK")
                return
            }
            guard (200...299).contains(http.statusCode) else { return }
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let batchSize = parsed["batch_size"] as? Int
            let flushIntervalMs = parsed["flush_interval_ms"] as? Int
            if batchSize != nil || flushIntervalMs != nil {
                queue?.applyRemoteConfig(
                    flushAt: batchSize,
                    flushIntervalSeconds: flushIntervalMs.map { Double($0) / 1000.0 }
                )
                log("remote config applied batch=\(String(describing: batchSize)) intervalMs=\(String(describing: flushIntervalMs))")
            }
        } catch {
            log("remote config fetch failed — sticking with defaults")
        }
    }

    public func identify(_ customerId: String, traits: AdfiniaTraits? = nil) {
        identify(.customerId(customerId), traits: traits)
    }

    public func identify(_ arg: AdfiniaIdentifyArg, traits: AdfiniaTraits? = nil) {
        guard guardCall("identify") else { return }
        var customerId: String? = nil
        var anonymousId: String? = nil
        var traitsJson: [String: AdfiniaJSONValue]? = AdfiniaJSONValue.fromDictionary(traits)

        switch arg {
        case .customerId(let id):
            customerId = id
        case .object(let cId, let aId, let t):
            customerId = cId
            anonymousId = aId
            if let t = t {
                let extra = AdfiniaJSONValue.fromDictionary(t) ?? [:]
                if var merged = traitsJson {
                    for (k, v) in extra { merged[k] = v }
                    traitsJson = merged
                } else {
                    traitsJson = extra
                }
            }
        }

        guard let identity = identityStore else { return }
        identity.identify(customerId: customerId, traits: traitsJson, anonymousId: anonymousId)
        enqueue(makePayload(
            type: .identify,
            event: nil,
            previousId: nil,
            properties: nil,
            traits: identity.traits
        ))
    }

    public func track(_ event: String, properties: AdfiniaProperties? = nil) {
        guard guardCall("track") else { return }
        guard !event.isEmpty else {
            log("track() called without an event name — dropped")
            return
        }
        enqueue(makePayload(
            type: .track,
            event: event,
            previousId: nil,
            properties: AdfiniaJSONValue.fromDictionary(properties),
            traits: nil
        ))
    }

    public func screen(_ name: String? = nil, properties: AdfiniaProperties? = nil) {
        guard guardCall("screen") else { return }
        enqueue(makePayload(
            type: .screen,
            event: name,
            previousId: nil,
            properties: AdfiniaJSONValue.fromDictionary(properties),
            traits: nil
        ))
    }

    public func alias(_ newId: String, previousId: String? = nil) {
        guard guardCall("alias") else { return }
        guard !newId.isEmpty else {
            log("alias() called without a newId — dropped")
            return
        }
        guard let identity = identityStore else { return }
        let prev = previousId ?? identity.customerId ?? identity.anonymousId
        enqueue(makeAliasPayload(newId: newId, previousId: prev))
        identity.identify(customerId: newId, traits: nil, anonymousId: nil)
    }

    public func reset() {
        guard initialised else { return }
        identityStore?.reset()
        log("identity reset — new anonymous_id minted")
    }

    public func flush() async {
        guard initialised else { return }
        await queue?.flush()
    }

    // MARK: - Internal (test) accessors

    func _identityStore() -> IdentityStore? { identityStore }
    func _queueCount() -> Int { queue?.count ?? 0 }
    func _drainQueue() -> [AdfiniaPayload] { queue?.drainAll() ?? [] }

    // MARK: - Private

    private func makePayload(
        type: AdfiniaPayloadType,
        event: String?,
        previousId: String?,
        properties: [String: AdfiniaJSONValue]?,
        traits: [String: AdfiniaJSONValue]?
    ) -> AdfiniaPayload {
        guard let identity = identityStore else {
            // Defensive — should never hit if `guardCall` passed.
            return AdfiniaPayload(
                type: type,
                event: event,
                customerId: nil,
                anonymousId: "",
                previousId: previousId,
                properties: properties,
                traits: traits,
                context: AdfiniaContextBuilder.build(),
                sentAt: ISO8601DateFormatter.adfinia.string(from: now()),
                messageId: UUIDv7.generate()
            )
        }
        return AdfiniaPayload(
            type: type,
            event: event,
            customerId: identity.customerId,
            anonymousId: identity.anonymousId,
            previousId: previousId,
            properties: properties,
            traits: traits,
            context: AdfiniaContextBuilder.build(),
            sentAt: ISO8601DateFormatter.adfinia.string(from: now()),
            messageId: UUIDv7.generate()
        )
    }

    private func makeAliasPayload(newId: String, previousId: String) -> AdfiniaPayload {
        AdfiniaPayload(
            type: .alias,
            event: nil,
            customerId: newId,
            anonymousId: identityStore?.anonymousId ?? "",
            previousId: previousId,
            properties: nil,
            traits: nil,
            context: AdfiniaContextBuilder.build(),
            sentAt: ISO8601DateFormatter.adfinia.string(from: now()),
            messageId: UUIDv7.generate()
        )
    }

    private func enqueue(_ payload: AdfiniaPayload) {
        queue?.enqueue(payload)
    }

    private func guardCall(_ label: String) -> Bool {
        if !initialised {
            print("[adfinia] \(label)() called before initialize()")
            return false
        }
        if let consent = config?.consent {
            let granted: Bool = consent()
            if !granted {
                log("\(label)() dropped — consent gate returned false")
                return false
            }
        }
        return true
    }

    private func log(_ message: String) {
        guard config?.debug == true else { return }
        print("[adfinia] \(message)")
    }
}

extension ISO8601DateFormatter {
    /// Shared formatter with fractional seconds — matches the web SDK's
    /// `new Date().toISOString()` output to the millisecond.
    static let adfinia: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
