// Control-plane HTTP client — the request path for endpoints that are NOT
// part of the batched event pipeline (`Transport` owns /track + /identify).
//
// Push registration (`POST /api/v1/push/register`, `DELETE
// /api/v1/push/register/{token}`) and the in-app notification inbox
// (`GET /api/v1/notifications`, `POST /notifications/{id}/read`,
// `POST /notifications/read-all`, `GET /api/v1/notifications/stream`) all
// speak plain request/response JSON with the same `Bearer <writeKey>` +
// `X-Adfinia-SDK-Version` auth the event transport uses. They do not batch,
// retry, or buffer — a failed call is surfaced to the caller, not queued.
//
// A protocol fronts the concrete URLSession client so tests can inject a
// stub (see PushRegistrationTests / NotificationsInboxTests) without a live
// server, exactly as `Transport` does for the event path.

import Foundation

/// Outcome of a control-plane request. `data` is the raw response body (may
/// be empty). `ok` is true for 2xx.
struct ControlPlaneResult {
    let ok: Bool
    let status: Int?
    let data: Data

    static let networkError = ControlPlaneResult(ok: false, status: nil, data: Data())
}

/// Narrow surface the push + inbox modules need. Concrete impl is
/// ``HttpControlPlaneClient``; tests pass a fake.
protocol ControlPlaneTransport: AnyObject {
    func post(_ path: String, body: Data?) async -> ControlPlaneResult
    func get(_ path: String, query: [URLQueryItem]) async -> ControlPlaneResult
    func delete(_ path: String) async -> ControlPlaneResult

    /// Build the fully-qualified `URLRequest` for an SSE / streaming GET so the
    /// caller can drive it with `URLSession.bytes(for:)`. Returns nil if the
    /// URL cannot be formed.
    func streamRequest(_ path: String, query: [URLQueryItem]) -> URLRequest?
}

/// Default URLSession-backed control-plane client. Mirrors ``HttpTransport``'s
/// host-normalisation + auth-header stamping.
final class HttpControlPlaneClient: ControlPlaneTransport {
    private let host: String
    private let writeKey: String
    private let session: URLSession

    init(host: String, writeKey: String, session: URLSession = .shared) {
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.writeKey = writeKey
        self.session = session
    }

    func post(_ path: String, body: Data?) async -> ControlPlaneResult {
        guard var request = makeRequest(path, query: []) else { return .networkError }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await run(request)
    }

    func get(_ path: String, query: [URLQueryItem]) async -> ControlPlaneResult {
        guard var request = makeRequest(path, query: query) else { return .networkError }
        request.httpMethod = "GET"
        return await run(request)
    }

    func delete(_ path: String) async -> ControlPlaneResult {
        guard var request = makeRequest(path, query: []) else { return .networkError }
        request.httpMethod = "DELETE"
        return await run(request)
    }

    func streamRequest(_ path: String, query: [URLQueryItem]) -> URLRequest? {
        guard var request = makeRequest(path, query: query) else { return nil }
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // SSE connections are long-lived; give them a generous idle timeout so
        // the 25s server keepalive comment never trips a client timeout.
        request.timeoutInterval = 3600
        return request
    }

    private func makeRequest(_ path: String, query: [URLQueryItem]) -> URLRequest? {
        guard var components = URLComponents(string: host + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AdfiniaVersion.sdkVersionHeader, forHTTPHeaderField: "X-Adfinia-SDK-Version")
        return request
    }

    private func run(_ request: URLRequest) async -> ControlPlaneResult {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ControlPlaneResult(ok: false, status: nil, data: data)
            }
            let ok = (200...299).contains(http.statusCode)
            return ControlPlaneResult(ok: ok, status: http.statusCode, data: data)
        } catch {
            return .networkError
        }
    }
}

/// Host-app metadata shared by the context builder and the push registrar.
enum AdfiniaAppInfo {
    /// `CFBundleShortVersionString` from the host's Info.plist, if present.
    static func version() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
