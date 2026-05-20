// Internal — wire format. Encodes byte-for-byte to the shape that
// `/api/v1/track` + `/api/v1/identify` accept (see api/api/openapi.yaml).
//
// The SDK keeps a richer internal payload (separate `event` / `sent_at`
// / `message_id` / `context` fields) and the transport flattens it into
// the wire-shape on send. This mirrors the layering in
// `sdks/web/src/transport.ts`.

import Foundation

enum AdfiniaPayloadType: String, Codable {
    case track, identify, page, screen, alias
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
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([AdfiniaJSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: AdfiniaJSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Best-effort conversion from `[String: Any]` so callers can pass
    /// dictionary literals as Swift expects. Unsupported types (Date,
    /// Data, custom classes) are dropped with no error — the SDK never
    /// crashes the host app over a malformed property.
    static func from(_ value: Any?) -> AdfiniaJSONValue {
        guard let value = value else { return .null }
        if value is NSNull { return .null }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .int(Int64(v)) }
        if let v = value as? Int64 { return .int(v) }
        if let v = value as? Double { return .double(v) }
        if let v = value as? Float { return .double(Double(v)) }
        if let v = value as? NSNumber {
            // NSNumber is the unboxing path for ObjC literals — branch on
            // the underlying type so we don't promote everything to Double.
            let typeStr = String(cString: v.objCType)
            switch typeStr {
            case "c", "B": return .bool(v.boolValue)
            case "f", "d": return .double(v.doubleValue)
            default: return .int(v.int64Value)
            }
        }
        if let v = value as? String { return .string(v) }
        if let v = value as? [Any] { return .array(v.map { AdfiniaJSONValue.from($0) }) }
        if let v = value as? [String: Any] {
            var out: [String: AdfiniaJSONValue] = [:]
            for (k, val) in v { out[k] = AdfiniaJSONValue.from(val) }
            return .object(out)
        }
        // Unknown — coerce to string description so the event still ships.
        return .string(String(describing: value))
    }

    static func fromDictionary(_ dict: [String: Any]?) -> [String: AdfiniaJSONValue]? {
        guard let dict = dict else { return nil }
        var out: [String: AdfiniaJSONValue] = [:]
        for (k, v) in dict { out[k] = AdfiniaJSONValue.from(v) }
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
    var os: AdfiniaOSContext?
    var app: AdfiniaAppContext?
    var device: AdfiniaDeviceContext?
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

/// Wire payload for `POST /api/v1/identify`.
struct AdfiniaIdentifyWire: Encodable {
    let customer_id: String?
    let anonymous_id: String?
    let traits: [String: AdfiniaJSONValue]?
    let context: [String: String]?
}

/// Wire payload for `POST /api/v1/track`. Note `event_name` — the API uses
/// that name (the SDK uses `event` internally for parity with the web SDK).
struct AdfiniaTrackWire: Encodable {
    let customer_id: String?
    let anonymous_id: String?
    let event_name: String
    let properties: [String: AdfiniaJSONValue]?
    let context: [String: String]?
    let occurred_at: String?
}
