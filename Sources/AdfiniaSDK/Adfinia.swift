// AdfiniaSDK — public surface. Mirrors @adfinia/sdk-web 1:1.
// Skeleton implementation: API stubs are wired through to internal modules
// (transport / persistence / queue) that are currently no-op placeholders.
// See NEXT.md for the implementation backlog.

import Foundation

/// Per-event / per-identify properties bag.
public typealias AdfiniaProperties = [String: Any]
public typealias AdfiniaTraits = [String: Any]
public typealias AdfiniaConsent = () -> Bool

/// SDK configuration.
public struct AdfiniaConfig {
    public let writeKey: String
    public let host: String
    public let debug: Bool
    public let consent: AdfiniaConsent?
    public let flushAt: Int
    public let flushIntervalSeconds: TimeInterval
    public let maxQueueSize: Int

    public init(
        writeKey: String,
        host: String = "https://events.adfinia.com",
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

/// What identify() accepts: either a customer id string or a struct.
public enum AdfiniaIdentifyArg {
    case customerId(String)
    case object(customerId: String?, anonymousId: String?, traits: AdfiniaTraits?)
}

/// The Adfinia SDK singleton. Mirrors the web SDK's public surface so a
/// team that learns one knows the other.
public enum Adfinia {
    nonisolated(unsafe) private static var client = AdfiniaClient()

    public static func initialize(_ config: AdfiniaConfig) {
        client.initialize(config)
    }

    public static func identify(_ customerId: String, traits: AdfiniaTraits? = nil) {
        client.identify(.customerId(customerId), traits: traits)
    }

    public static func identify(_ arg: AdfiniaIdentifyArg, traits: AdfiniaTraits? = nil) {
        client.identify(arg, traits: traits)
    }

    public static func track(_ event: String, properties: AdfiniaProperties? = nil) {
        client.track(event, properties: properties)
    }

    public static func screen(_ name: String? = nil, properties: AdfiniaProperties? = nil) {
        client.screen(name, properties: properties)
    }

    public static func alias(_ newId: String, previousId: String? = nil) {
        client.alias(newId, previousId: previousId)
    }

    public static func reset() {
        client.reset()
    }

    public static func flush() async {
        await client.flush()
    }
}
