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
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(
            writeKey: "pk_test_x",
            flushAt: 1,
            flushIntervalSeconds: 60
        ))
        client.track("Order Completed", properties: ["total": 49.99])
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        let event = transport.sentEvents[0]
        XCTAssertEqual(event.type, .track)
        XCTAssertEqual(event.event, "Order Completed")
        XCTAssertEqual(event.properties?["total"], .double(49.99))
        XCTAssertFalse(event.anonymousId.isEmpty)
        XCTAssertFalse(event.messageId.isEmpty)
        XCTAssertEqual(event.context.library.name, "adfinia-sdk-ios")
    }

    func testIdentifyStringSetsCustomerIdAndEmitsIdentifyEvent() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_42", traits: ["plan": "growth"])
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.sentEvents[0].type, .identify)
        XCTAssertEqual(transport.sentEvents[0].customerId, "cust_42")
        XCTAssertEqual(transport.sentEvents[0].traits?["plan"], .string("growth"))
    }

    func testIdentifyObjectFormIsAccepted() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify(
            .object(customerId: "cust_99", anonymousId: nil, traits: ["tier": "enterprise"])
        )
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.sentEvents[0].customerId, "cust_99")
        XCTAssertEqual(transport.sentEvents[0].traits?["tier"], .string("enterprise"))
    }

    func testSubsequentTrackCarriesTheCustomerIdFromIdentify() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 2, flushIntervalSeconds: 60))
        client.identify("cust_42")
        client.track("Order Completed")
        let succeeded = await waitUntil { transport.sentEvents.count == 2 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.sentEvents[1].customerId, "cust_42")
    }

    func testOptOutSingleEmitsOneConsentEventWithChannelsAsArray() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.optOut("email")
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        let event = transport.sentEvents[0]
        XCTAssertEqual(event.type, .track)
        XCTAssertEqual(event.event, "consent_updated")
        XCTAssertEqual(event.properties?["channels"], .array([.string("email")]))
        XCTAssertEqual(event.properties?["status"], .string("opted_out"))
    }

    func testOptInArrayNormalizesChannelsAndKeepsThemAnArray() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.optIn(["  Email ", "WhatsApp", "SMS"])
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            transport.sentEvents[0].properties?["channels"],
            .array([.string("email"), .string("whatsapp"), .string("sms")])
        )
        XCTAssertEqual(transport.sentEvents[0].properties?["status"], .string("opted_in"))
    }

    func testSetConsentAcceptsUnknownOpenChannelStrings() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.setConsent(["rcs", "voice", "app_notification"], status: "opted_in")
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            transport.sentEvents[0].properties?["channels"],
            .array([.string("rcs"), .string("voice"), .string("app_notification")])
        )
    }

    func testInvalidConsentStatusSendsNothing() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.setConsent("email", status: "maybe")
        client.setConsent("sms", status: "nope")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }

    func testEmptyConsentChannelListIsASoftNoOp() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.optOut("   ")
        client.optIn([])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }

    func testConsentEventCarriesCurrentIdentity() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 2, flushIntervalSeconds: 60))
        client.identify("cust_42")
        client.optOut("whatsapp")
        let succeeded = await waitUntil { transport.sentEvents.count == 2 }
        XCTAssertTrue(succeeded)
        let consent = transport.sentEvents.first { $0.event == "consent_updated" }
        XCTAssertEqual(consent?.customerId, "cust_42")
    }

    // alias() is deprecated (1.1.0) and is now a true no-op: it enqueues
    // and transmits nothing, and does not mutate identity. Anonymous-to-known
    // promotion happens via identify() instead.
    func testAliasIsANoOpAndEmitsNoEvent() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.identify("cust_existing")
        let sentAfterIdentify = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(sentAfterIdentify)
        let countBefore = transport.sentEvents.count
        client.alias("cust_new", previousId: "cust_old")
        // Give any (erroneous) enqueue a chance to flush; expect none.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, countBefore)
        XCTAssertEqual(client.queueCount(), 0)
        // Identity is untouched by alias().
        XCTAssertEqual(client.identityStoreForTests()?.customerId, "cust_existing")
    }

    func testResetMintsNewAnonymousId() {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x"))
        let before = client.identityStoreForTests()?.anonymousId
        client.identify("cust_42")
        client.reset()
        XCTAssertNil(client.identityStoreForTests()?.customerId)
        XCTAssertNotEqual(client.identityStoreForTests()?.anonymousId, before)
    }

    func testConsentGateDropsEventsWhenReturningFalse() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        let lock = NSLock()
        var consented = false
        client.initialize(AdfiniaConfig(
            writeKey: "pk_test_x",
            consent: { lock.lock(); defer { lock.unlock() }; return consented },
            flushAt: 1,
            flushIntervalSeconds: 60
        ))
        client.track("Order Completed")
        // Buffer should be empty — event was dropped.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)

        lock.lock(); consented = true; lock.unlock()
        client.track("Order Completed")
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
    }

    func testTrackWithoutEventNameIsNoOp() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.track("")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }

    func testInitCalledTwiceIsNoOp() {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x"))
        let id = client.identityStoreForTests()?.anonymousId
        client.initialize(AdfiniaConfig(writeKey: "pk_test_y"))
        XCTAssertEqual(client.identityStoreForTests()?.anonymousId, id)
    }

    func testFlushTriggersTransportOnDemand() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 100, flushIntervalSeconds: 60))
        client.track("a")
        client.track("b")
        XCTAssertEqual(transport.sentEvents.count, 0)
        await client.flush()
        XCTAssertEqual(transport.sentEvents.count, 2)
    }

    func testPublicMethodsBeforeInitDoNotCrash() {
        let client = AdfiniaClient(hooks: ClientHooks())
        client.track("Order Completed")
        client.identify("cust_42")
        client.screen("Pricing")
        client.optOut(["email", "sms"])
        client.alias("new")
        client.reset()
        // No assertion — we just want to confirm no crash, no enqueue.
        XCTAssertEqual(client.queueCount(), 0)
    }

    func testScreenEmitsScreenEvent() async throws {
        let transport = CapturingTransport()
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 1, flushIntervalSeconds: 60))
        client.screen("Pricing", properties: ["plan": "growth"])
        let succeeded = await waitUntil { transport.sentEvents.count == 1 }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.sentEvents[0].type, .screen)
        XCTAssertEqual(transport.sentEvents[0].event, "Pricing")
        XCTAssertEqual(transport.sentEvents[0].properties?["plan"], .string("growth"))
    }

    func testIdentityPersistsAcrossClientReconstruction() async throws {
        let store = InMemoryStore()
        let transport1 = CapturingTransport()
        let client1 = makeClient(transport: transport1, store: store)
        client1.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 100, flushIntervalSeconds: 60))
        client1.identify("cust_persistent")
        let anon1 = client1.identityStoreForTests()?.anonymousId

        // Rebuild — simulates a fresh app launch with the same UserDefaults.
        let transport2 = CapturingTransport()
        let client2 = makeClient(transport: transport2, store: store)
        client2.initialize(AdfiniaConfig(writeKey: "pk_test_x", flushAt: 100, flushIntervalSeconds: 60))
        XCTAssertEqual(client2.identityStoreForTests()?.customerId, "cust_persistent")
        XCTAssertEqual(client2.identityStoreForTests()?.anonymousId, anon1)
    }

    func testSharedSingletonIsReachable() {
        // Smoke-check the public singleton entry point — ensures the
        // `Adfinia.shared` API compiles + is reachable. The shared
        // instance is process-wide; we don't mutate it from this test.
        _ = Adfinia.shared
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
        let client = makeClient(transport: transport)
        client.initialize(AdfiniaConfig(
            writeKey: "pk_test_x",
            consent: { false },  // always denied
            flushAt: 1,
            flushIntervalSeconds: 60
        ))
        client.track("Order Completed")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentEvents.count, 0)
    }
}
