// AdfiniaSDK — public surface. Mirrors `@adfinia/sdk-web` 1:1 so a team
// that's integrated the web SDK already knows this one.
//
// Usage:
//
//   import AdfiniaSDK
//
//   Adfinia.initialize(AdfiniaConfig(
//       writeKey: "pk_live_your_public_key",
//       debug: true,
//       consent: { UserDefaults.standard.bool(forKey: "analytics_consent") }
//   ))
//
//   Adfinia.identify("cust_42", traits: ["plan": "growth"])
//   Adfinia.track("Order Completed", properties: ["total": 49.99])
//
// The `Adfinia` enum hosts a process-wide singleton (`Adfinia.shared`).
// For multi-tenant servers and isolated test contexts, instantiate
// `AdfiniaClient` directly.

import Foundation

/// Per-event / per-identify properties bag. Values must be JSON-encodable
/// (bool / number / string / null / arrays / nested dictionaries). Unknown
/// types are converted to their string description rather than crashing
/// the host app.
public typealias AdfiniaProperties = [String: Any]
public typealias AdfiniaTraits = [String: Any]

/// Consent gate. The SDK invokes this on every public API call. Returning
/// `false` drops the call silently — no buffering, no network. Returning
/// `true` (or omitting the gate) lets the SDK proceed.
public typealias AdfiniaConsent = () -> Bool

/// SDK configuration.
public struct AdfiniaConfig {
    /// The tenant's write-only public key, issued from the Adfinia console
    /// at `/settings/integrations/sdk-keys`. Prefixed `pk_live_` or
    /// `pk_test_`. Safe to bundle in client-side code.
    public let writeKey: String

    /// Override the ingest host. Defaults to `https://api.adfinia.com`.
    /// Self-hosted tenants point this at their own ingress.
    public let host: String

    /// Log SDK internals to stdout. Off by default.
    public let debug: Bool

    /// Consent gate. See ``AdfiniaConsent``. If omitted, the SDK assumes
    /// consent — that matches the server-side use case but is the wrong
    /// default for App Store apps. Always pass a real gate in production.
    public let consent: AdfiniaConsent?

    /// Batch flush size. Default 50 events.
    public let flushAt: Int

    /// Batch flush interval in seconds. Default 5.
    public let flushIntervalSeconds: TimeInterval

    /// Max queued events. Past this, oldest are dropped first. Default 1000.
    public let maxQueueSize: Int

    public init(
        writeKey: String,
        host: String = "https://api.adfinia.com",
        debug: Bool = false,
        consent: AdfiniaConsent? = nil,
        flushAt: Int = 50,
        flushIntervalSeconds: TimeInterval = 5,
        maxQueueSize: Int = 1000
    ) {
        self.writeKey = writeKey
        self.host = host
        self.debug = debug
        self.consent = consent
        self.flushAt = flushAt
        self.flushIntervalSeconds = flushIntervalSeconds
        self.maxQueueSize = maxQueueSize
    }
}

/// What `identify()` accepts: either a `customer_id` string or a struct
/// carrying any combination of `customerId` / `anonymousId` / `traits`.
public enum AdfiniaIdentifyArg {
    case customerId(String)
    case object(customerId: String?, anonymousId: String?, traits: AdfiniaTraits?)
}

/// Top-level entry point. Holds a process-wide ``AdfiniaClient`` singleton
/// so the host app doesn't have to manage instances. Thread-safe.
public enum Adfinia {
    /// Process-wide singleton. Customer code calls `Adfinia.identify(...)`,
    /// `Adfinia.track(...)`, etc. — these all forward to `shared`.
    public static let shared = AdfiniaClient()

    public static func initialize(_ config: AdfiniaConfig) {
        shared.initialize(config)
    }

    public static func identify(_ customerId: String, traits: AdfiniaTraits? = nil) {
        shared.identify(customerId, traits: traits)
    }

    public static func identify(_ arg: AdfiniaIdentifyArg, traits: AdfiniaTraits? = nil) {
        shared.identify(arg, traits: traits)
    }

    public static func track(_ event: String, properties: AdfiniaProperties? = nil) {
        shared.track(event, properties: properties)
    }

    public static func screen(_ name: String? = nil, properties: AdfiniaProperties? = nil) {
        shared.screen(name, properties: properties)
    }

    /// Record a write-only consent decision for one or more channels. `status`
    /// is `"opted_in"` or `"opted_out"`. Channels are open strings (not an
    /// enum) — the backend owns the valid-channel registry. Emits one
    /// `consent_updated` event with `channels` always an array. Never throws.
    public static func setConsent(_ channels: [String], status: String) {
        shared.setConsent(channels, status: status)
    }

    /// setConsent for a single channel.
    public static func setConsent(_ channel: String, status: String) {
        shared.setConsent(channel, status: status)
    }

    /// Shorthand for setConsent(channels, status: "opted_in").
    public static func optIn(_ channels: [String]) {
        shared.optIn(channels)
    }

    /// Shorthand for setConsent(channel, status: "opted_in").
    public static func optIn(_ channel: String) {
        shared.optIn(channel)
    }

    /// Shorthand for setConsent(channels, status: "opted_out").
    public static func optOut(_ channels: [String]) {
        shared.optOut(channels)
    }

    /// Shorthand for setConsent(channel, status: "opted_out").
    public static func optOut(_ channel: String) {
        shared.optOut(channel)
    }

    @available(*, deprecated, message: "alias() is a no-op; anonymous sessions are promoted automatically by identify()")
    public static func alias(_ newId: String, previousId: String? = nil) {
        shared.alias(newId, previousId: previousId)
    }

    public static func reset() {
        shared.reset()
    }

    public static func flush() async {
        await shared.flush()
    }
}
