// AdfiniaClient — public-surface tests. Mirrors `sdks/web/tests/client.test.ts`.

import XCTest
@testable import AdfiniaSDK

final class AdfiniaSDKTests: XCTestCase {
    private func makeClient(transport: Transport, store: AdfiniaKVStore = InMemoryStore()) -> AdfiniaClient {
        var hooks = ClientHooks()
        hooks.transport = transport
        hooks.store = store
        hooks.loggerOverride = SilentLogger()
        return AdfiniaClient(hooks: hooks)
    }

    func testTrackEnqueuesAnEventWithTheRightShape() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(
            writeKey: "pk_test_x",
            flushAt: 1,
            flushIntervalSeconds: 60
        ))
        c.track("Order Completed", properties: ["total": 49.99])
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        let ev = transport.sentEvents[0]
        XCTAssertEqual(ev.type, .track)
        XCTAssertEqual(ev.event, "Order Completed")
        XCTAssertEqual(ev.properties?["total"], .double(49.99))
        XCTAssertFalse(ev.anonymousId.isEmpty)
        XCTAssertFalse(ev.messageId.isEmpty)
        XCTAssertEqual(ev.context.library.name, "adfinia-sdk-ios")
    }

    func testIdentifyStringSetsCustomerIdAndEmitsIdentifyEvent() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.identify("cust_42", traits: ["plan": "growth"])
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.sentEvents[0].type, .identify)
        XCTAssertEqual(transport.sentEvents[0].customerId, "cust_42")
        XCTAssertEqual(transport.sentEvents[0].traits?["plan"], .string("growth"))
    }

    func testIdentifyObjectFormIsAccepted() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.identify(
            .object(customerId: "cust_99", anonymousId: nil, traits: ["tier": "enterprise"])
        )
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.sentEvents[0].customerId, "cust_99")
        XCTAssertEqual(transport.sentEvents[0].traits?["tier"], .string("enterprise"))
    }

    func testSubsequentTrackCarriesTheCustomerIdFromIdentify() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 2, flushIntervalSeconds: 60))
        c.identify("cust_42")
        c.track("Order Completed")
        let ok = await waitUntil { transport.sentEvents.count == 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.sentEvents[1].customerId, "cust_42")
    }

    func testOptOutSingleEmitsOneConsentEventWithChannelsAsArray() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.optOut("email")
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        let ev = transport.sentEvents[0]
        XCTAssertEqual(ev.type, .track)
        XCTAssertEqual(ev.event, "consent_updated")
        XCTAssertEqual(ev.properties?["channels"], .array([.string("email")]))
        XCTAssertEqual(ev.properties?["status"], .string("opted_out"))
    }

    func testOptInArrayNormalizesChannelsAndKeepsThemAnArray() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.optIn(["  Email ", "WhatsApp", "SMS"])
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(
            transport.sentEvents[0].properties?["channels"],
            .array([.string("email"), .string("whatsapp"), .string("sms")])
        )
        XCTAssertEqual(transport.sentEvents[0].properties?["status"], .string("opted_in"))
    }

    func testSetConsentAcceptsUnknownOpenChannelStrings() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.setConsent(["rcs", "voice", "app_notification"], status: "opted_in")
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(
            transport.sentEvents[0].properties?["channels"],
            .array([.string("rcs"), .string("voice"), .string("app_notification")])
        )
    }

    func testInvalidConsentStatusSendsNothing() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.setConsent("email", status: "maybe")
        c.setConsent("sms", status: "nope")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }

    func testEmptyConsentChannelListIsASoftNoOp() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.optOut("   ")
        c.optIn([])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }

    func testConsentEventCarriesCurrentIdentity() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 2, flushIntervalSeconds: 60))
        c.identify("cust_42")
        c.optOut("whatsapp")
        let ok = await waitUntil { transport.sentEvents.count == 2 }
        XCTAssertTrue(ok)
        let consent = transport.sentEvents.first { $0.event == "consent_updated" }
        XCTAssertEqual(consent?.customerId, "cust_42")
    }

    // alias() is deprecated (1.1.0) and is now a true no-op: it enqueues
    // and transmits nothing, and does not mutate identity. Anonymous-to-known
    // promotion happens via identify() instead.
    func testAliasIsANoOpAndEmitsNoEvent() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.identify("cust_existing")
        let sentAfterIdentify = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(sentAfterIdentify)
        let countBefore = transport.sentEvents.count
        c.alias("cust_new", previousId: "cust_old")
        // Give any (erroneous) enqueue a chance to flush; expect none.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, countBefore)
        XCTAssertEqual(c._queueCount(), 0)
        // Identity is untouched by alias().
        XCTAssertEqual(c._identityStore()?.customerId, "cust_existing")
    }

    func testResetMintsNewAnonymousId() {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x"))
        let before = c._identityStore()?.anonymousId
        c.identify("cust_42")
        c.reset()
        XCTAssertNil(c._identityStore()?.customerId)
        XCTAssertNotEqual(c._identityStore()?.anonymousId, before)
    }

    func testConsentGateDropsEventsWhenReturningFalse() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        let lock = NSLock()
        var consented = false
        c.initialize(AdfiniaConfig(
            writeKey: "pk_test_x",
            consent: { lock.lock(); defer { lock.unlock() }; return consented },
            flushAt: 1,
            flushIntervalSeconds: 60
        ))
        c.track("Order Completed")
        // Buffer should be empty — event was dropped.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)

        lock.lock(); consented = true; lock.unlock()
        c.track("Order Completed")
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
    }

    func testTrackWithoutEventNameIsNoOp() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.track("")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }

    func testInitCalledTwiceIsNoOp() {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x"))
        let id = c._identityStore()?.anonymousId
        c.initialize(AdfiniaConfig(writeKey: "pk_test_y"))
        XCTAssertEqual(c._identityStore()?.anonymousId, id)
    }

    func testFlushTriggersTransportOnDemand() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 100, flushIntervalSeconds: 60))
        c.track("a")
        c.track("b")
        XCTAssertEqual(transport.sentEvents.count, 0)
        await c.flush()
        XCTAssertEqual(transport.sentEvents.count, 2)
    }

    func testPublicMethodsBeforeInitDoNotCrash() {
        let c = AdfiniaClient(hooks: ClientHooks())
        c.track("Order Completed")
        c.identify("cust_42")
        c.screen("Pricing")
        c.optOut(["email", "sms"])
        c.alias("new")
        c.reset()
        // No assertion — we just want to confirm no crash, no enqueue.
        XCTAssertEqual(c._queueCount(), 0)
    }

    func testScreenEmitsScreenEvent() async throws {
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        c.screen("Pricing", properties: ["plan": "growth"])
        let ok = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.sentEvents[0].type, .screen)
        XCTAssertEqual(transport.sentEvents[0].event, "Pricing")
        XCTAssertEqual(transport.sentEvents[0].properties?["plan"], .string("growth"))
    }

    func testIdentityPersistsAcrossClientReconstruction() async throws {
        let store = InMemoryStore()
        let t1 = CapturingTransport()
        let c1 = makeClient(transport: t1, store: store)
        c1.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 100, flushIntervalSeconds: 60))
        c1.identify("cust_persistent")
        let anon1 = c1._identityStore()?.anonymousId

        // Rebuild — simulates a fresh app launch with the same UserDefaults.
        let t2 = CapturingTransport()
        let c2 = makeClient(transport: t2, store: store)
        c2.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 100, flushIntervalSeconds: 60))
        XCTAssertEqual(c2._identityStore()?.customerId, "cust_persistent")
        XCTAssertEqual(c2._identityStore()?.anonymousId, anon1)
    }

    func testSharedSingletonIsReachable() {
        // Smoke-check the public singleton entry point — ensures the
        // `Adfinia.shared` API compiles + is reachable. The shared
        // instance is process-wide; we don't mutate it from this test.
        let _ = Adfinia.shared
        // Public static methods exist on the enum.
        // Calling them before initialize() warns but doesn't crash.
        Adfinia.track("smoke-test-event-that-will-be-dropped")
    }

    func testConsentGateThatThrowsIsTreatedAsNoConsent() async throws {
        // Swift consent closures can't throw directly (the typealias is
        // `() -> Bool`), but a closure can still trap via `fatalError`
        // or return false on internal error. This test verifies the
        // gate's return value is respected.
        let transport = CapturingTransport()
        let c = makeClient(transport: transport)
        c.initialize(AdfiniaConfig(
            writeKey: "pk_test_x",
            consent: { false },  // always denied
            flushAt: 1,
            flushIntervalSeconds: 60
        ))
        c.track("Order Completed")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }
}
