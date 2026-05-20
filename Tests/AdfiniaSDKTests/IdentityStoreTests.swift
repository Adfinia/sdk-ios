// Mirrors `sdks/web/tests/identity.test.ts`.

import XCTest
@testable import AdfiniaSDK

final class IdentityStoreTests: XCTestCase {
    func testMintsAnonymousIdOnFirstConstruction() {
        let store = IdentityStore(store: InMemoryStore())
        XCTAssertFalse(store.anonymousId.isEmpty)
        XCTAssertEqual(store.anonymousId.count, 36, "Should be UUID-shaped")
        XCTAssertNil(store.customerId)
    }

    func testPersistsAnonymousIdAcrossConstructions() {
        let backing = InMemoryStore()
        let s1 = IdentityStore(store: backing)
        let id1 = s1.anonymousId
        let s2 = IdentityStore(store: backing)
        XCTAssertEqual(s2.anonymousId, id1)
    }

    func testRecordsCustomerIdAndMergesTraits() {
        let store = IdentityStore(store: InMemoryStore())
        store.identify(
            customerId: "cust_42",
            traits: ["plan": .string("growth")],
            anonymousId: nil
        )
        XCTAssertEqual(store.customerId, "cust_42")
        XCTAssertEqual(store.traits?["plan"], .string("growth"))

        store.identify(
            customerId: "cust_42",
            traits: ["country": .string("AE")],
            anonymousId: nil
        )
        XCTAssertEqual(store.traits?["plan"], .string("growth"))
        XCTAssertEqual(store.traits?["country"], .string("AE"))
    }

    func testResetMintsNewAnonymousIdAndClearsCustomer() {
        let store = IdentityStore(store: InMemoryStore())
        let original = store.anonymousId
        store.identify(customerId: "cust_42", traits: nil, anonymousId: nil)
        store.reset()
        XCTAssertNil(store.customerId)
        XCTAssertNotEqual(store.anonymousId, original)
    }

    func testIdentifyWithExplicitAnonymousIdReplacesIt() {
        let store = IdentityStore(store: InMemoryStore())
        store.identify(customerId: nil, traits: nil, anonymousId: "anon_explicit")
        XCTAssertEqual(store.anonymousId, "anon_explicit")
    }

    func testSetResolvedCustomerIdDoesNotClearTraits() {
        let store = IdentityStore(store: InMemoryStore())
        store.identify(customerId: nil, traits: ["plan": .string("growth")], anonymousId: nil)
        store.setResolvedCustomerId("server-resolved-uuid")
        XCTAssertEqual(store.customerId, "server-resolved-uuid")
        XCTAssertEqual(store.traits?["plan"], .string("growth"))
    }

    func testRecoversFromCorruptStorageBlob() {
        let backing = InMemoryStore()
        backing.set("not-valid-json-{", forKey: IdentityStore.storageKey)
        let store = IdentityStore(store: backing)
        // Should mint a fresh identity rather than crash or hand back "".
        XCTAssertFalse(store.anonymousId.isEmpty)
    }
}
