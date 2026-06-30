// Mirrors `sdks/web/tests/transport.test.ts`. URLSession is intercepted
// via a stub URLProtocol so we capture exactly what the SDK puts on the
// wire.

import XCTest
@testable import AdfiniaSDK

/// Captures every URLRequest hitting URLSession and returns a stub
/// response. Tests configure it via the static `nextResponse` block.
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        var status: Int
        var body: Data
    }

    static let lock = NSLock()
    private static var _requestLog: [URLRequest] = []
    private static var _responseProvider: ((URLRequest) -> StubResponse?)?
    private static var _throwError: Bool = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _requestLog.removeAll()
        _responseProvider = nil
        _throwError = false
    }

    static func setResponse(_ provider: @escaping (URLRequest) -> StubResponse?) {
        lock.lock(); defer { lock.unlock() }
        _responseProvider = provider
    }

    static func setThrows() {
        lock.lock(); defer { lock.unlock() }
        _throwError = true
    }

    static var requestLog: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requestLog
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol surfaces the request body via `httpBodyStream`, not
        // `httpBody`, when called from URLSession. Materialise it.
        var captured = request
        if let stream = request.httpBodyStream {
            captured.httpBody = Self.readStream(stream)
        }

        StubURLProtocol.lock.lock()
        StubURLProtocol._requestLog.append(captured)
        let throwError = StubURLProtocol._throwError
        let provider = StubURLProtocol._responseProvider
        StubURLProtocol.lock.unlock()

        if throwError {
            let e = NSError(domain: "AdfiniaTest", code: -1009, userInfo: nil)
            client?.urlProtocol(self, didFailWithError: e)
            return
        }

        let stub = provider?(captured) ?? StubResponse(status: 202, body: Data("{}".utf8))
        let url = request.url ?? URL(string: "https://test.invalid")!
        let resp = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}

final class TransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func buildEvent(
        type: AdfiniaPayloadType = .track,
        event: String = "e",
        customerId: String? = nil,
        traits: [String: AdfiniaJSONValue]? = nil,
        previousId: String? = nil
    ) -> AdfiniaPayload {
        AdfiniaPayload(
            type: type,
            event: event,
            customerId: customerId,
            anonymousId: "anon",
            previousId: previousId,
            properties: nil,
            traits: traits,
            context: AdfiniaContext(
                library: AdfiniaLibraryInfo(name: "adfinia-sdk-ios", version: "test")
            ),
            sentAt: ISO8601DateFormatter.adfinia.string(from: Date()),
            messageId: "msg"
        )
    }

    // A lone track-like event ships as a 1-element /track/batch (NOT single
    // /track) so the server stamps test/live from the API key.
    func testPostsTrackEventsWithBearerAuth() async throws {
        StubURLProtocol.setResponse { _ in .init(status: 202, body: Data(#"{"accepted":1,"rejected":0,"batch_id":"b"}"#.utf8)) }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk_test_x", session: session)

        let res = await t.send([buildEvent(event: "Order Completed")])
        XCTAssertTrue(res.ok)
        XCTAssertEqual(StubURLProtocol.requestLog.count, 1)
        let req = StubURLProtocol.requestLog[0]
        XCTAssertEqual(req.url?.absoluteString, "https://events.adfinia.com/api/v1/track/batch")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test_x")
        let body = try XCTUnwrap(req.httpBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = try XCTUnwrap(parsed?["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let ev = events[0]
        XCTAssertEqual(ev["event_name"] as? String, "Order Completed")
        XCTAssertEqual(ev["anonymous_id"] as? String, "anon")
        XCTAssertNotNil(ev["occurred_at"])
        let context = ev["context"] as? [String: String]
        XCTAssertEqual(context?["library.name"], "adfinia-sdk-ios")
        XCTAssertEqual(context?["message_id"], "msg")
    }

    // A lone identify STILL uses the single /identify endpoint (it resolves
    // customer_id and carries no environment tag) — locks the surgical split.
    func testLoneIdentifyUsesSingleIdentifyEndpoint() async throws {
        StubURLProtocol.setResponse { _ in .init(status: 202, body: Data(#"{"customer_id":"cust_9"}"#.utf8)) }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk_test_x", session: session)

        let res = await t.send([buildEvent(type: .identify, event: "", customerId: "cust_9")])
        XCTAssertTrue(res.ok)
        XCTAssertEqual(StubURLProtocol.requestLog.count, 1)
        XCTAssertEqual(StubURLProtocol.requestLog[0].url?.absoluteString, "https://events.adfinia.com/api/v1/identify")
        XCTAssertEqual(res.resolvedCustomerId, "cust_9")
    }

    // AGENT-SDK-INGEST-KAFKA (2026-05-21) — mixed batches now hit the
    // /batch endpoints, one request per kind, instead of one request per
    // event. The resolvedCustomerId field is no longer parsed from the
    // batch endpoint (the server doesn't echo it for identify-batch
    // because the batch is async); the SDK falls back to its own
    // anonymous_id until the response from a subsequent single identify.
    func testRoutesIdentifyEventsToIdentifyBatchEndpoint() async throws {
        StubURLProtocol.setResponse { _ in
            .init(status: 202, body: Data(#"{"accepted":1,"rejected":0,"batch_id":"b"}"#.utf8))
        }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk_test_x", session: session)

        let identifyEvent = buildEvent(
            type: .identify,
            event: "",
            customerId: "cust_42",
            traits: ["plan": .string("growth")]
        )
        let res = await t.send([buildEvent(event: "boot"), buildEvent(event: "boot2"), identifyEvent])
        XCTAssertTrue(res.ok)
        let urls = StubURLProtocol.requestLog.map { $0.url?.absoluteString ?? "" }
        // Batch endpoints — one call per kind.
        XCTAssertTrue(urls.contains("https://events.adfinia.com/api/v1/track/batch"))
        XCTAssertTrue(urls.contains("https://events.adfinia.com/api/v1/identify/batch"))

        let identifyReq = StubURLProtocol.requestLog.first { $0.url?.path == "/api/v1/identify/batch" }
        let body = try XCTUnwrap(identifyReq?.httpBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = parsed?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?[0]["customer_id"] as? String, "cust_42")
        let traits = events?[0]["traits"] as? [String: Any]
        XCTAssertEqual(traits?["plan"] as? String, "growth")
    }

    func testSynthesisesEventNameForPageScreenAlias() async throws {
        StubURLProtocol.setResponse { _ in .init(status: 202, body: Data("{}".utf8)) }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk_test_x", session: session)
        _ = await t.send([
            buildEvent(type: .page, event: ""),
            buildEvent(type: .screen, event: ""),
            buildEvent(type: .alias, event: "", previousId: "cust_old")
        ])
        // All three land in one /track/batch request.
        XCTAssertEqual(StubURLProtocol.requestLog.count, 1)
        let req = StubURLProtocol.requestLog[0]
        XCTAssertEqual(req.url?.path, "/api/v1/track/batch")
        let body = try XCTUnwrap(req.httpBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = parsed?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 3)
        XCTAssertEqual(events?[0]["event_name"] as? String, "$page_viewed")
        XCTAssertEqual(events?[1]["event_name"] as? String, "$screen_viewed")
        XCTAssertEqual(events?[2]["event_name"] as? String, "$alias")
        let aliasProps = events?[2]["properties"] as? [String: Any]
        XCTAssertEqual(aliasProps?["previous_id"] as? String, "cust_old")
    }

    // AGENT-SDK-INGEST-KAFKA (2026-05-21) — multi-event track batch goes
    // to the batch endpoint as a single request.
    func testMultiEventTrackBatchUsesBatchEndpoint() async throws {
        StubURLProtocol.setResponse { _ in
            .init(status: 202, body: Data(#"{"accepted":3,"rejected":0,"batch_id":"b1"}"#.utf8))
        }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk_test_x", session: session)
        let res = await t.send([
            buildEvent(event: "a"),
            buildEvent(event: "b"),
            buildEvent(event: "c"),
        ])
        XCTAssertTrue(res.ok)
        XCTAssertEqual(StubURLProtocol.requestLog.count, 1)
        let req = StubURLProtocol.requestLog[0]
        XCTAssertEqual(req.url?.path, "/api/v1/track/batch")
        let body = try XCTUnwrap(req.httpBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = parsed?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 3)
        XCTAssertEqual(events?.map { $0["event_name"] as? String }, ["a", "b", "c"])
    }

    func testReturnsPermanentTrueOn4xx() async throws {
        StubURLProtocol.setResponse { _ in .init(status: 400, body: Data("bad".utf8)) }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk", session: session)
        let res = await t.send([buildEvent()])
        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.permanent)
        XCTAssertEqual(res.status, 400)
    }

    func testReturnsPermanentFalseOn5xx() async throws {
        StubURLProtocol.setResponse { _ in .init(status: 503, body: Data("oops".utf8)) }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk", session: session)
        let res = await t.send([buildEvent()])
        XCTAssertFalse(res.ok)
        XCTAssertFalse(res.permanent)
        XCTAssertEqual(res.status, 503)
    }

    func testTreatsNetworkErrorsAsRetryable() async throws {
        StubURLProtocol.setThrows()
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk", session: session)
        let res = await t.send([buildEvent()])
        XCTAssertFalse(res.ok)
        XCTAssertFalse(res.permanent)
    }

    func testNoOpsOnEmptyBatch() async throws {
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com", writeKey: "pk", session: session)
        let res = await t.send([])
        XCTAssertTrue(res.ok)
        XCTAssertEqual(StubURLProtocol.requestLog.count, 0)
    }

    func testStripsTrailingSlashFromHost() async throws {
        StubURLProtocol.setResponse { _ in .init(status: 202, body: Data("{}".utf8)) }
        let session = AdfiniaURLSessionFactory.session(with: StubURLProtocol.self)
        let t = HttpTransport(host: "https://events.adfinia.com/", writeKey: "pk", session: session)
        _ = await t.send([buildEvent()])
        XCTAssertEqual(StubURLProtocol.requestLog.first?.url?.absoluteString, "https://events.adfinia.com/api/v1/track/batch")
    }
}
