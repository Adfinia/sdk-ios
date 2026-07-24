// Push-registration + in-app-inbox tests. Exercise the control-plane path
// (POST /push/register, GET/POST /notifications) through a capturing stub
// transport injected via ClientHooks, mirroring how AdfiniaSDKTests injects a
// CapturingTransport for the event pipeline.

import XCTest
@testable import AdfiniaSDK

/// Captures every control-plane request and returns a scripted result.
final class CapturingControlPlane: ControlPlaneTransport, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let path: String
        let body: Data?
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private var nextResult = ControlPlaneResult(ok: true, status: 200, data: Data("{}".utf8))

    func setNextResult(_ result: ControlPlaneResult) {
        lock.lock(); defer { lock.unlock() }
        nextResult = result
    }

    var lastCall: Call? {
        lock.lock(); defer { lock.unlock() }
        return calls.last
    }

    private func record(_ method: String, _ path: String, _ body: Data?) -> ControlPlaneResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(method: method, path: path, body: body))
        return nextResult
    }

    func post(_ path: String, body: Data?) async -> ControlPlaneResult { record("POST", path, body) }
    func get(_ path: String, query: [URLQueryItem]) async -> ControlPlaneResult {
        var comps = URLComponents(string: path)!
        comps.queryItems = query
        return record("GET", comps.string ?? path, nil)
    }
    func delete(_ path: String) async -> ControlPlaneResult { record("DELETE", path, nil) }
    func streamRequest(_ path: String, query: [URLQueryItem]) -> URLRequest? {
        var comps = URLComponents(string: "https://test.invalid" + path)!
        comps.queryItems = query
        return URLRequest(url: comps.url!)
    }
}

final class PushAndInboxTests: XCTestCase {
    private func makeClient(
        transport: Transport,
        controlPlane: ControlPlaneTransport
    ) -> AdfiniaClient {
        var hooks = ClientHooks()
        hooks.transport = transport
        hooks.controlPlane = controlPlane
        hooks.store = InMemoryStore()
        hooks.loggerOverride = SilentLogger()
        return AdfiniaClient(hooks: hooks)
    }

    // MARK: - Push registration

    func testHexEncodeMatchesAPNsCanonicalForm() {
        let bytes = Data([0x00, 0x0f, 0xa1, 0xff])
        XCTAssertEqual(AdfiniaClient.hexEncode(deviceToken: bytes), "000fa1ff")
    }

    func testRegisterForPushPostsMirroredPayload() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: true, status: 201, data: Data("{}".utf8)))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_42")

        let tokenBytes = Data([0xab, 0xcd, 0xef, 0x01])
        let result = await client.performPushRegister(hexToken: AdfiniaClient.hexEncode(deviceToken: tokenBytes))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.token, "abcdef01")

        let call = try XCTUnwrap(controlPlane.lastCall)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/api/v1/push/register")
        let body = try XCTUnwrap(call.body)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["token"] as? String, "abcdef01")
        XCTAssertEqual(parsed["platform"] as? String, "ios")
        XCTAssertEqual(parsed["customer_id"] as? String, "cust_42")
        // device_id doubles as the install-scoped anonymous_id (RN parity).
        let anon = try XCTUnwrap(parsed["anonymous_id"] as? String)
        XCTAssertFalse(anon.isEmpty)
        XCTAssertEqual(parsed["device_id"] as? String, anon)
    }

    func testRegisterForPushEmitsPushRegisteredEvent() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: true, status: 201, data: Data("{}".utf8)))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))

        _ = await client.performPushRegister(hexToken: "deadbeef00")

        let succeeded = await waitUntil { events.sentEvents.contains { $0.event == "push_registered" } }
        XCTAssertTrue(succeeded)
        let event = try XCTUnwrap(events.sentEvents.first { $0.event == "push_registered" })
        XCTAssertEqual(event.properties?["platform"], .string("ios"))
    }

    func testRegisterBeforeInitIsNotInitialised() async {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        let client = makeClient(transport: events, controlPlane: controlPlane)
        let result = await client.performPushRegister(hexToken: "abc123")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "not_initialised")
        XCTAssertNil(controlPlane.lastCall)
    }

    func testRegisterWithEmptyTokenIsRejected() async {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        let result = await client.performPushRegister(hexToken: "   ")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "empty_token")
        XCTAssertNil(controlPlane.lastCall)
    }

    func testRegisterServerErrorReportsPostFailedAndNoEvent() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: false, status: 400, data: Data("bad".utf8)))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))

        let result = await client.performPushRegister(hexToken: "abc123def0")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "post_failed")
        // A failed registration must NOT emit push_registered.
        let sawEvent = await waitUntil(timeout: 0.4) { events.sentEvents.contains { $0.event == "push_registered" } }
        XCTAssertFalse(sawEvent)
    }

    func testUnregisterDeletesTokenPath() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: true, status: 200, data: Data("{}".utf8)))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))

        let result = await client.performPushUnregister(hexToken: "abcdef01")
        XCTAssertTrue(result.ok)
        let call = try XCTUnwrap(controlPlane.lastCall)
        XCTAssertEqual(call.method, "DELETE")
        XCTAssertEqual(call.path, "/api/v1/push/register/abcdef01")
    }

    // MARK: - Inbox

    private let listBody = """
    {
      "data": [
        {
          "id": "n1", "title": "Welcome", "body": "Hello there",
          "severity": "info", "dismissable": true, "deep_link": "adfinia://home",
          "data": {"campaign_id": "c1"}, "read": false,
          "created_at": "2026-07-20T10:00:00.000Z", "expires_at": null
        },
        {
          "id": "n2", "title": "Read one", "body": "Body",
          "severity": "warning", "dismissable": false, "read": true,
          "created_at": "2026-07-19T10:00:00.000Z",
          "read_at": "2026-07-19T11:00:00.000Z"
        }
      ],
      "next_cursor": "cursor_abc",
      "has_more": true
    }
    """

    func testInboxListDecodesAndSendsContactAndStatus() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: true, status: 200, data: Data(listBody.utf8)))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_42")

        let result = await client.notifications.list(status: .unread, limit: 20)
        guard case .success(let page) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(page.data.count, 2)
        XCTAssertEqual(page.nextCursor, "cursor_abc")
        XCTAssertTrue(page.hasMore)

        let first = page.data[0]
        XCTAssertEqual(first.id, "n1")
        XCTAssertEqual(first.title, "Welcome")
        XCTAssertEqual(first.severity, "info")
        XCTAssertTrue(first.dismissable)
        XCTAssertEqual(first.deepLink, "adfinia://home")
        XCTAssertEqual(first.data?["campaign_id"], .string("c1"))
        XCTAssertFalse(first.read)
        XCTAssertEqual(page.data[1].read, true)
        XCTAssertEqual(page.data[1].readAt, "2026-07-19T11:00:00.000Z")

        let call = try XCTUnwrap(controlPlane.lastCall)
        XCTAssertEqual(call.method, "GET")
        XCTAssertTrue(call.path.contains("/api/v1/notifications"))
        XCTAssertTrue(call.path.contains("contact_id=cust_42"), "path was \(call.path)")
        XCTAssertTrue(call.path.contains("status=unread"), "path was \(call.path)")
    }

    func testInboxListFallsBackToAnonymousContactId() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(
            ControlPlaneResult(ok: true, status: 200, data: Data(#"{"data":[],"has_more":false}"#.utf8))
        )
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        // No identify() — should use the anonymous_id.
        let anon = try XCTUnwrap(client.identityStoreForTests()?.anonymousId)

        _ = await client.notifications.list()
        let call = try XCTUnwrap(controlPlane.lastCall)
        XCTAssertTrue(call.path.contains("contact_id=\(anon)"), "path was \(call.path)")
    }

    func testMarkReadPostsToIdRoute() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(
            ControlPlaneResult(ok: true, status: 200, data: Data(#"{"id":"n1","read":true}"#.utf8))
        )
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_42")

        let result = await client.notifications.markRead("n1")
        guard case .success = result else { return XCTFail("expected success") }
        let call = try XCTUnwrap(controlPlane.lastCall)
        XCTAssertEqual(call.method, "POST")
        XCTAssertTrue(call.path.hasPrefix("/api/v1/notifications/n1/read"), "path was \(call.path)")
        XCTAssertTrue(call.path.contains("contact_id=cust_42"), "path was \(call.path)")
    }

    func testMarkAllReadReturnsUpdatedCount() async throws {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: true, status: 200, data: Data(#"{"updated":7}"#.utf8)))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_42")

        let result = await client.notifications.markAllRead()
        guard case .success(let count) = result else { return XCTFail("expected success") }
        XCTAssertEqual(count, 7)
        let call = try XCTUnwrap(controlPlane.lastCall)
        XCTAssertEqual(call.method, "POST")
        XCTAssertTrue(call.path.hasPrefix("/api/v1/notifications/read-all"), "path was \(call.path)")
    }

    func testInboxBeforeInitIsNotInitialised() async {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        let client = makeClient(transport: events, controlPlane: controlPlane)
        let result = await client.notifications.list()
        guard case .failure(let err) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(err, .notInitialised)
    }

    func testInboxServerErrorSurfacesStatus() async {
        let events = CapturingTransport()
        let controlPlane = CapturingControlPlane()
        controlPlane.setNextResult(ControlPlaneResult(ok: false, status: 403, data: Data()))
        let client = makeClient(transport: events, controlPlane: controlPlane)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_42")
        let result = await client.notifications.list()
        guard case .failure(let err) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(err, .requestFailed(status: 403))
    }

    // The SSE frame shape (no read/read_at) still decodes into AdfiniaNotification.
    func testNotificationDecodesFromSSEFrameWithoutReadState() throws {
        let sse = #"{"id":"n9","title":"Live","body":"Now","severity":"info","#
            + #""dismissable":true,"created_at":"2026-07-20T12:00:00.000Z"}"#
        let notif = try JSONDecoder().decode(AdfiniaNotification.self, from: Data(sse.utf8))
        XCTAssertEqual(notif.id, "n9")
        XCTAssertFalse(notif.read)
        XCTAssertNil(notif.readAt)
    }
}
