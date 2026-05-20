// HTTP transport. Mirrors `sdks/web/src/transport.ts`.
//
// - `identify` payloads → POST /api/v1/identify
// - `track` / `page` / `screen` / `alias` → POST /api/v1/track
// - 2xx → ok
// - 4xx → permanent (drop, do not retry)
// - 5xx + network errors → retryable
//
// The endpoints are single-event today, so a batched send fans out to
// one request per payload via async/await `withTaskGroup`. When the
// `{batch: [...]}` endpoint lands we'll swap to a single POST.

import Foundation

/// Outcome of a batch send. The queue uses this to decide whether to
/// drop, retry, or advance.
struct TransportResult: Equatable {
    let ok: Bool
    /// `true` if the failure is permanent (4xx) — events should be dropped.
    let permanent: Bool
    /// HTTP status code from the worst result in the batch, if any.
    let status: Int?
    /// For identify calls, the server-resolved `customer_id` (if returned).
    let resolvedCustomerId: String?

    static let okEmpty = TransportResult(ok: true, permanent: false, status: nil, resolvedCustomerId: nil)
}

/// Protocol so tests can swap a fake transport in.
protocol Transport: AnyObject {
    func send(_ batch: [AdfiniaPayload]) async -> TransportResult
}

/// Default URLSession-backed transport.
final class HttpTransport: Transport {
    private let host: String
    private let writeKey: String
    private let session: URLSession

    init(host: String, writeKey: String, session: URLSession = .shared) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.writeKey = writeKey
        self.session = session
    }

    func send(_ batch: [AdfiniaPayload]) async -> TransportResult {
        if batch.isEmpty { return .okEmpty }

        var results: [TransportResult] = []
        results.reserveCapacity(batch.count)
        // Send sequentially to keep the test surface deterministic. Real
        // throughput is dominated by the 5s flush cadence, not per-event
        // parallelism, so this is the right trade-off until the batch
        // endpoint lands.
        for payload in batch {
            results.append(await sendOne(payload))
        }

        var ok = true
        var permanent = false
        var status: Int? = nil
        var resolvedCustomerId: String? = nil
        for r in results {
            if r.ok {
                if let id = r.resolvedCustomerId { resolvedCustomerId = id }
            } else {
                ok = false
                if r.permanent { permanent = true }
                status = r.status
            }
        }
        return TransportResult(ok: ok, permanent: permanent, status: status, resolvedCustomerId: resolvedCustomerId)
    }

    private func sendOne(_ payload: AdfiniaPayload) async -> TransportResult {
        let path = payload.type == .identify ? "/api/v1/identify" : "/api/v1/track"
        guard let url = URL(string: host + path) else {
            return TransportResult(ok: false, permanent: true, status: nil, resolvedCustomerId: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        let body: Data
        do {
            if payload.type == .identify {
                let wire = toIdentifyWire(payload)
                body = try encoder.encode(wire)
            } else {
                let wire = toTrackWire(payload)
                body = try encoder.encode(wire)
            }
        } catch {
            // Encoding shouldn't fail for our types; if it does, the
            // payload is malformed — drop it.
            return TransportResult(ok: false, permanent: true, status: nil, resolvedCustomerId: nil)
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return TransportResult(ok: false, permanent: false, status: nil, resolvedCustomerId: nil)
            }
            if (200...299).contains(http.statusCode) {
                // Best-effort parse of `customer_id` from the identify response.
                var resolved: String? = nil
                if payload.type == .identify {
                    if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        resolved = parsed["customer_id"] as? String
                    }
                }
                return TransportResult(ok: true, permanent: false, status: http.statusCode, resolvedCustomerId: resolved)
            }
            let permanent = (400...499).contains(http.statusCode)
            return TransportResult(ok: false, permanent: permanent, status: http.statusCode, resolvedCustomerId: nil)
        } catch {
            // Network failure — retryable.
            return TransportResult(ok: false, permanent: false, status: nil, resolvedCustomerId: nil)
        }
    }

    private func toIdentifyWire(_ p: AdfiniaPayload) -> AdfiniaIdentifyWire {
        return AdfiniaIdentifyWire(
            customer_id: p.customerId,
            anonymous_id: p.anonymousId,
            traits: p.traits,
            context: flattenContext(p.context, messageId: p.messageId, sdkEventType: p.type.rawValue)
        )
    }

    private func toTrackWire(_ p: AdfiniaPayload) -> AdfiniaTrackWire {
        let eventName = p.event?.isEmpty == false ? p.event! : synthesiseName(p.type)
        return AdfiniaTrackWire(
            customer_id: p.customerId,
            anonymous_id: p.anonymousId,
            event_name: eventName,
            properties: mergedProperties(p),
            context: flattenContext(p.context, messageId: p.messageId, sdkEventType: p.type.rawValue),
            occurred_at: p.sentAt
        )
    }

    private func synthesiseName(_ type: AdfiniaPayloadType) -> String {
        switch type {
        case .page: return "$page_viewed"
        case .screen: return "$screen_viewed"
        case .alias: return "$alias"
        default: return "$unknown"
        }
    }

    /// For alias events, carry the previous_id in properties so the server's
    /// identity-graph stitching picks it up.
    private func mergedProperties(_ p: AdfiniaPayload) -> [String: AdfiniaJSONValue]? {
        if p.type == .alias, let prev = p.previousId {
            var props = p.properties ?? [:]
            props["previous_id"] = .string(prev)
            return props
        }
        return p.properties
    }

    // MARK: - Internal helpers exposed for tests
    func _toIdentifyWireForTests(_ p: AdfiniaPayload) -> AdfiniaIdentifyWire {
        toIdentifyWire(p)
    }
    func _toTrackWireForTests(_ p: AdfiniaPayload) -> AdfiniaTrackWire {
        toTrackWire(p)
    }
}

/// Helper so test code can build a private `URLSession` with a stub
/// `URLProtocol` injected. Used in `TransportTests`.
enum AdfiniaURLSessionFactory {
    static func session(with protocolClass: AnyClass) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}
