// Internal — wire format. Encodes byte-for-byte to the shape that
// `/api/v1/track` + `/api/v1/identify` accept (see api/api/openapi.yaml).
//
// The SDK keeps a richer internal payload (separate `event` / `sent_at`
// / `message_id` / `context` fields) and the transport flattens it into
// the wire-shape on send. This mirrors the layering in
// `sdks/web/src/transport.ts`.

import Foundation

enum AdfiniaPayloadType: String, Codable {
    case track, identify, page, screen
}

/// JSON-safe value wrapper. The Swift `Codable` system can't encode
/// `[String: Any]` directly, so the public `AdfiniaProperties` /
/// `AdfiniaTraits` typealiases are converted to ``AdfiniaJSONValue`` at
/// the boundary. Supports null, bool, Int, Double, String, array, object.
public indirect enum AdfiniaJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AdfiniaJSONValue])
    case object([String: AdfiniaJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let decoded = try? container.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? container.decode(Int64.self) {
            self = .int(decoded)
        } else if let decoded = try? container.decode(Double.self) {
            self = .double(decoded)
        } else if let decoded = try? container.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? container.decode([AdfiniaJSONValue].self) {
            self = .array(decoded)
        } else if let decoded = try? container.decode([String: AdfiniaJSONValue].self) {
            self = .object(decoded)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Best-effort conversion from `[String: Any]` so callers can pass
    /// dictionary literals as Swift expects. Unsupported types (Date,
    /// Data, custom classes) are dropped with no error — the SDK never
    /// crashes the host app over a malformed property.
    static func from(_ value: Any?) -> AdfiniaJSONValue {
        guard let value = value else { return .null }
        if value is NSNull { return .null }
        if let scalar = scalarValue(value) { return scalar }
        if let array = value as? [Any] { return .array(array.map { AdfiniaJSONValue.from($0) }) }
        if let object = value as? [String: Any] {
            var out: [String: AdfiniaJSONValue] = [:]
            for (key, element) in object { out[key] = AdfiniaJSONValue.from(element) }
            return .object(out)
        }
        // Unknown — coerce to string description so the event still ships.
        return .string(String(describing: value))
    }

    /// Cast the primitive/number cases in the SAME priority order as the
    /// original inline chain, returning nil for non-scalar inputs so the
    /// caller can fall through to the array / object / string paths. Split
    /// out to keep ``from(_:)`` under the cyclomatic-complexity limit.
    private static func scalarValue(_ value: Any) -> AdfiniaJSONValue? {
        if let boolValue = value as? Bool { return .bool(boolValue) }
        if let intValue = value as? Int { return .int(Int64(intValue)) }
        if let int64Value = value as? Int64 { return .int(int64Value) }
        if let doubleValue = value as? Double { return .double(doubleValue) }
        if let floatValue = value as? Float { return .double(Double(floatValue)) }
        if let number = value as? NSNumber { return numberValue(number) }
        if let stringValue = value as? String { return .string(stringValue) }
        return nil
    }

    /// NSNumber is the unboxing path for ObjC literals — branch on the
    /// underlying type so we don't promote everything to Double.
    private static func numberValue(_ number: NSNumber) -> AdfiniaJSONValue {
        let typeStr = String(cString: number.objCType)
        switch typeStr {
        case "c", "B": return .bool(number.boolValue)
        case "f", "d": return .double(number.doubleValue)
        default: return .int(number.int64Value)
        }
    }

    static func fromDictionary(_ dict: [String: Any]?) -> [String: AdfiniaJSONValue]? {
        guard let dict = dict else { return nil }
        var out: [String: AdfiniaJSONValue] = [:]
        for (key, element) in dict { out[key] = AdfiniaJSONValue.from(element) }
        return out
    }
}

/// Library identifier. Carried in every event's context block so the
/// server can route SDK-side telemetry separately from server-side.
struct AdfiniaLibraryInfo: Codable, Equatable {
    let name: String
    let version: String
}

/// Per-event context. Mirrors the web SDK's `AdfiniaContext` shape.
struct AdfiniaContext: Codable, Equatable {
    let library: AdfiniaLibraryInfo
    var locale: String?
    var timezone: String?
    var osContext: AdfiniaOSContext?
    var app: AdfiniaAppContext?
    var device: AdfiniaDeviceContext?

    // Persisted key stays "os" (the queue serialises this to disk); only the
    // Swift property is renamed to satisfy the min-identifier-length rule.
    enum CodingKeys: String, CodingKey {
        case library
        case locale
        case timezone
        case osContext = "os"
        case app
        case device
    }
}

struct AdfiniaOSContext: Codable, Equatable {
    var name: String?
    var version: String?
}

struct AdfiniaAppContext: Codable, Equatable {
    var name: String?
    var version: String?
    var build: String?
}

struct AdfiniaDeviceContext: Codable, Equatable {
    var model: String?
    var manufacturer: String?
}

/// Internal envelope. The transport flattens this into the wire shape
/// expected by `/api/v1/track` + `/api/v1/identify` on send.
struct AdfiniaPayload: Codable, Equatable {
    let type: AdfiniaPayloadType
    var event: String?
    var customerId: String?
    var anonymousId: String
    var previousId: String?
    var properties: [String: AdfiniaJSONValue]?
    var traits: [String: AdfiniaJSONValue]?
    var context: AdfiniaContext
    var sentAt: String  // ISO-8601 UTC.
    var messageId: String

    enum CodingKeys: String, CodingKey {
        case type
        case event
        case customerId = "customer_id"
        case anonymousId = "anonymous_id"
        case previousId = "previous_id"
        case properties
        case traits
        case context
        case sentAt = "sent_at"
        case messageId = "message_id"
    }
}

/// Wire payload for `POST /api/v1/identify`. CodingKeys map every field back
/// to the exact snake_case JSON keys the API expects, so the serialised bytes
/// are unchanged; only the Swift property names are camelCase.
struct AdfiniaIdentifyWire: Encodable {
    let customerId: String?
    let anonymousId: String?
    let traits: [String: AdfiniaJSONValue]?
    let context: [String: String]?

    enum CodingKeys: String, CodingKey {
        case customerId = "customer_id"
        case anonymousId = "anonymous_id"
        case traits
        case context
    }
}

/// Wire payload for `POST /api/v1/track`. The API field is `event_name` (the
/// SDK uses `event` internally for parity with the web SDK). CodingKeys map
/// every field back to the exact snake_case JSON keys, so the serialised bytes
/// are unchanged; only the Swift property names are camelCase.
struct AdfiniaTrackWire: Encodable {
    let customerId: String?
    let anonymousId: String?
    let eventName: String
    let properties: [String: AdfiniaJSONValue]?
    let context: [String: String]?
    let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case customerId = "customer_id"
        case anonymousId = "anonymous_id"
        case eventName = "event_name"
        case properties
        case context
        case occurredAt = "occurred_at"
    }
}
