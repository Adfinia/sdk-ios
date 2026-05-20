// Mirrors `sdks/web/tests/queue.test.ts`.
//
// Note: the iOS queue uses a real DispatchSourceTimer (not a virtualised
// clock), so timing-sensitive tests set `flushIntervalSeconds` to small
// real-time values and use `waitUntil` to poll for the expected state.

import XCTest
@testable import AdfiniaSDK

final class EventQueueTests: XCTestCase {
    func testFlushesWhenFlushAtIsHit() async throws {
        let transport = CapturingTransport()
        let q = EventQueue(config: EventQueueConfig(
            store: InMemoryStore(),
            transport: transport,
            flushAt: 2,
            flushIntervalSeconds: 60,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        q.enqueue(makePayload(event: "a"))
        q.enqueue(makePayload(event: "b"))

        let ok = await waitUntil { transport.calls == 1 }
        XCTAssertTrue(ok, "expected one flush after flushAt hit")
        XCTAssertEqual(transport.lastBatch?.count, 2)
        q.destroy()
    }

    func testFlushesOnInterval() async throws {
        let transport = CapturingTransport()
        let q = EventQueue(config: EventQueueConfig(
            store: InMemoryStore(),
            transport: transport,
            flushAt: 100,
            flushIntervalSeconds: 0.2,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        q.enqueue(makePayload(event: "a"))

        let ok = await waitUntil(timeout: 2) { transport.calls >= 1 }
        XCTAssertTrue(ok, "expected interval flush within 2s")
        q.destroy()
    }

    func testDropsEventsOnPermanentFailure() async throws {
        let transport = CapturingTransport()
        transport.setNextResult(
            TransportResult(ok: false, permanent: true, status: 400, resolvedCustomerId: nil)
        )
        let q = EventQueue(config: EventQueueConfig(
            store: InMemoryStore(),
            transport: transport,
            flushAt: 100,
            flushIntervalSeconds: 60,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        q.enqueue(makePayload(event: "a"))
        await q.flush()
        XCTAssertEqual(transport.calls, 1)
        XCTAssertEqual(q.count, 0, "buffer should be empty after permanent drop")
        q.destroy()
    }

    func testRetriesOnTransientFailureWithBackoff() async throws {
        let transport = CapturingTransport()
        transport.queueResults([
            TransportResult(ok: false, permanent: false, status: 502, resolvedCustomerId: nil),
            TransportResult(ok: false, permanent: false, status: 502, resolvedCustomerId: nil),
            TransportResult(ok: true, permanent: false, status: 202, resolvedCustomerId: nil)
        ])
        let q = EventQueue(config: EventQueueConfig(
            store: InMemoryStore(),
            transport: transport,
            flushAt: 1,
            flushIntervalSeconds: 60,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        q.enqueue(makePayload(event: "a"))
        // First failure should arrive almost immediately.
        let firstOk = await waitUntil(timeout: 2) { transport.calls >= 1 }
        XCTAssertTrue(firstOk, "first send did not happen")
        // Backoff is 1s then 2s — wait up to 5s for the third attempt.
        let thirdOk = await waitUntil(timeout: 6) { transport.calls >= 3 }
        XCTAssertTrue(thirdOk, "expected 3 attempts (2 retries) — got \(transport.calls)")
        XCTAssertEqual(q.count, 0, "buffer should be empty after success")
        q.destroy()
    }

    func testPersistsBufferedEventsAcrossReconstruction() async throws {
        let store = InMemoryStore()

        let neverTransport = CapturingTransport()
        neverTransport.setNextResult(
            TransportResult(ok: false, permanent: false, status: nil, resolvedCustomerId: nil)
        )
        let q1 = EventQueue(config: EventQueueConfig(
            store: store,
            transport: neverTransport,
            flushAt: 100,
            flushIntervalSeconds: 60,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        q1.enqueue(makePayload(event: "a"))
        q1.enqueue(makePayload(event: "b"))
        // Wait until persistence has happened (the workQueue is async).
        _ = await waitUntil { store.string(forKey: EventQueue.storageKey) != nil }
        q1.destroy()

        let okTransport = CapturingTransport()
        let q2 = EventQueue(config: EventQueueConfig(
            store: store,
            transport: okTransport,
            flushAt: 100,
            flushIntervalSeconds: 60,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        await q2.flush()
        XCTAssertEqual(okTransport.calls, 1)
        XCTAssertEqual(okTransport.lastBatch?.count, 2)
        q2.destroy()
    }

    func testCapsQueueAtMaxQueueSizeAndDropsOldest() async throws {
        let blockedTransport = CapturingTransport()
        blockedTransport.setNextResult(
            TransportResult(ok: false, permanent: false, status: nil, resolvedCustomerId: nil)
        )
        let q = EventQueue(config: EventQueueConfig(
            store: InMemoryStore(),
            transport: blockedTransport,
            flushAt: 1000,
            flushIntervalSeconds: 60,
            maxQueueSize: 3,
            logger: SilentLogger(),
            onResolvedCustomerId: nil
        ))
        for i in 0..<6 { q.enqueue(makePayload(event: "e\(i)")) }
        // Wait for all enqueues to settle on the work queue.
        _ = await waitUntil { q.count == 3 }
        let drained = q.drainAll()
        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual(drained.first?.event, "e3")
        XCTAssertEqual(drained.last?.event, "e5")
        q.destroy()
    }

    func testResolvedCustomerIdCallbackFires() async throws {
        let transport = CapturingTransport()
        transport.setNextResult(
            TransportResult(ok: true, permanent: false, status: 200, resolvedCustomerId: "uuid-from-server")
        )
        var resolvedSeen: String?
        let lock = NSLock()
        let q = EventQueue(config: EventQueueConfig(
            store: InMemoryStore(),
            transport: transport,
            flushAt: 1,
            flushIntervalSeconds: 60,
            maxQueueSize: 1000,
            logger: SilentLogger(),
            onResolvedCustomerId: { id in
                lock.lock(); resolvedSeen = id; lock.unlock()
            }
        ))
        q.enqueue(makePayload(event: "identify-payload", type: .identify))
        let ok = await waitUntil { lock.lock(); defer { lock.unlock() }; return resolvedSeen != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(resolvedSeen, "uuid-from-server")
        q.destroy()
    }
}
