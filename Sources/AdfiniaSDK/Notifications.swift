// In-app notification inbox client. Read-side companion to push: the backend
// writes in_app_notifications rows (via journeys / campaigns / SSE driver),
// and this client reads them for the host app to render a bell / inbox UI.
//
// Endpoints (contact-scoped, authed by the tenant SDK key):
//   GET  /api/v1/notifications?contact_id=&status=&cursor=&limit=
//   POST /api/v1/notifications/{id}/read?contact_id=
//   POST /api/v1/notifications/read-all?contact_id=
//   GET  /api/v1/notifications/stream?contact_id=          (SSE, optional)
//
// The typed ``AdfiniaNotification`` mirrors the backend InboxNotification row
// shape. The `contact_id` every endpoint needs defaults to the SDK's resolved
// identity (customer_id, else anonymous_id); callers can override it.

import Foundation

/// Read-state filter for ``AdfiniaNotifications/list(status:contactId:)``.
public enum AdfiniaNotificationStatus: String, Sendable {
    case all
    case unread
    case read
}

/// One in-app notification. Mirrors the backend `InboxNotification` row.
/// Timestamps are kept as ISO-8601 strings (as the wire delivers them) rather
/// than `Date` so a fractional-second variance never fails decoding — the same
/// posture the event payload takes with `sent_at`.
public struct AdfiniaNotification: Decodable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let severity: String
    public let dismissable: Bool
    public let deepLink: String?
    public let data: [String: AdfiniaJSONValue]?
    public let read: Bool
    public let createdAt: String?
    public let readAt: String?
    public let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body, severity, dismissable
        case deepLink = "deep_link"
        case data, read
        case createdAt = "created_at"
        case readAt = "read_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "info"
        dismissable = try c.decodeIfPresent(Bool.self, forKey: .dismissable) ?? true
        deepLink = try c.decodeIfPresent(String.self, forKey: .deepLink)
        data = try c.decodeIfPresent([String: AdfiniaJSONValue].self, forKey: .data)
        // SSE frames carry no read-state; default to unread there.
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    }

    /// Test-only memberwise initialiser (the wire path uses `init(from:)`).
    init(
        id: String, title: String, body: String, severity: String,
        dismissable: Bool, deepLink: String?, data: [String: AdfiniaJSONValue]?,
        read: Bool, createdAt: String?, readAt: String?, expiresAt: String?
    ) {
        self.id = id; self.title = title; self.body = body; self.severity = severity
        self.dismissable = dismissable; self.deepLink = deepLink; self.data = data
        self.read = read; self.createdAt = createdAt; self.readAt = readAt; self.expiresAt = expiresAt
    }
}

/// A page of notifications plus the cursor to fetch the next one.
public struct AdfiniaNotificationPage: Decodable, Equatable {
    public let data: [AdfiniaNotification]
    public let nextCursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent([AdfiniaNotification].self, forKey: .data) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// Errors the inbox surfaces. Kept small; network failures collapse to
/// `.requestFailed(status:)` with a nil status for transport-level errors.
public enum AdfiniaNotificationError: Error, Equatable {
    case notInitialised
    case noContactId
    case requestFailed(status: Int?)
    case decodeFailed
}

/// The `Adfinia.notifications` inbox surface. Holds a weak reference to the
/// client so it always reads the live control-plane transport + identity.
public final class AdfiniaNotifications {
    private weak var client: AdfiniaClient?

    init(client: AdfiniaClient) {
        self.client = client
    }

    // MARK: - List

    /// Fetch a page of notifications for the resolved contact.
    /// - Parameters:
    ///   - status: read-state filter (default `.all`).
    ///   - contactId: override the resolved contact id (customer_id / anonymous_id).
    ///   - cursor: opaque keyset cursor from a previous page's `nextCursor`.
    ///   - limit: page size; the backend clamps to its own maximum.
    public func list(
        status: AdfiniaNotificationStatus = .all,
        contactId: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> Result<AdfiniaNotificationPage, AdfiniaNotificationError> {
        guard let client, client.isInitialised, let transport = client.controlPlaneTransport else {
            return .failure(.notInitialised)
        }
        guard let contact = contactId ?? client.inboxContactId() else {
            return .failure(.noContactId)
        }

        var query = [
            URLQueryItem(name: "contact_id", value: contact),
            URLQueryItem(name: "status", value: status.rawValue),
        ]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }

        let res = await transport.get("/api/v1/notifications", query: query)
        guard res.ok else { return .failure(.requestFailed(status: res.status)) }
        do {
            let page = try JSONDecoder().decode(AdfiniaNotificationPage.self, from: res.data)
            return .success(page)
        } catch {
            client.debugLog("notifications.list() decode failed")
            return .failure(.decodeFailed)
        }
    }

    // MARK: - Mark read

    /// Mark a single notification read (idempotent).
    @discardableResult
    public func markRead(
        _ id: String,
        contactId: String? = nil
    ) async -> Result<Void, AdfiniaNotificationError> {
        guard let client, client.isInitialised, let transport = client.controlPlaneTransport else {
            return .failure(.notInitialised)
        }
        guard let contact = contactId ?? client.inboxContactId() else {
            return .failure(.noContactId)
        }
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let query = [URLQueryItem(name: "contact_id", value: contact)]
        let path = pathWithQuery("/api/v1/notifications/\(encodedId)/read", query: query)
        let res = await transport.post(path, body: nil)
        return res.ok ? .success(()) : .failure(.requestFailed(status: res.status))
    }

    /// Mark every unread notification read for the contact. Returns the count
    /// the backend reports as updated.
    @discardableResult
    public func markAllRead(
        contactId: String? = nil
    ) async -> Result<Int, AdfiniaNotificationError> {
        guard let client, client.isInitialised, let transport = client.controlPlaneTransport else {
            return .failure(.notInitialised)
        }
        guard let contact = contactId ?? client.inboxContactId() else {
            return .failure(.noContactId)
        }
        let query = [URLQueryItem(name: "contact_id", value: contact)]
        let path = pathWithQuery("/api/v1/notifications/read-all", query: query)
        let res = await transport.post(path, body: nil)
        guard res.ok else { return .failure(.requestFailed(status: res.status)) }
        // Best-effort parse of `{"updated": N}`; absence is not an error.
        if let parsed = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any],
           let updated = parsed["updated"] as? Int {
            return .success(updated)
        }
        return .success(0)
    }

    // MARK: - SSE stream

    /// Live notification stream over Server-Sent Events. Yields each
    /// notification as the backend publishes it (plus an initial replay of
    /// unread history). The stream ends when the task is cancelled or the
    /// connection drops; callers reconnect by requesting a new stream.
    ///
    /// Available on iOS 15+/macOS 12+ (uses `URLSession.bytes(for:)`). The
    /// stream is best-effort — a transport error simply finishes it.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    public func stream(contactId: String? = nil) -> AsyncStream<AdfiniaNotification> {
        AsyncStream { continuation in
            guard let client, client.isInitialised,
                  let transport = client.controlPlaneTransport,
                  let contact = contactId ?? client.inboxContactId(),
                  let request = transport.streamRequest(
                    "/api/v1/notifications/stream",
                    query: [URLQueryItem(name: "contact_id", value: contact)]
                  )
            else {
                continuation.finish()
                return
            }

            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        continuation.finish()
                        return
                    }
                    // Parse the SSE frame stream: accumulate `data:` lines until
                    // a blank line, then decode the buffered JSON as one event.
                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            if let notif = Self.decodeSSE(dataBuffer) {
                                continuation.yield(notif)
                            }
                            dataBuffer = ""
                        } else if line.hasPrefix("data:") {
                            let piece = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            dataBuffer += piece
                        }
                        // `:` comment frames (keepalive / ready) and `event:` lines
                        // are ignored — we key off the buffered `data:` payload.
                    }
                } catch {
                    // Network drop / cancellation — end the stream cleanly.
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decodeSSE(_ json: String) -> AdfiniaNotification? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AdfiniaNotification.self, from: data)
    }

    /// Fold query items into a path string. Used for POST endpoints whose
    /// scope lives in the query (contact_id), since ``ControlPlaneTransport/post``
    /// takes only a path + body.
    private func pathWithQuery(_ path: String, query: [URLQueryItem]) -> String {
        guard !query.isEmpty, var components = URLComponents(string: path) else { return path }
        components.queryItems = query
        // percentEncodedQuery preserves the encoding the client will re-parse.
        if let q = components.percentEncodedQuery { return path + "?" + q }
        return path
    }
}
