# AdfiniaSDK iOS — next implementation steps

Round 2 (2026-05-20) landed the real implementation. `NEXT-IOS-1..4` and
`NEXT-IOS-7` are now done. Remaining items are platform-niceties + the
final publish step.

## Done in v0.2.0

| ID | Title | Status |
|----|-------|--------|
| NEXT-IOS-1 | UUIDv7 generator (RFC 9562 §6.2 monotonic counter) | Done — `Sources/AdfiniaSDK/UUIDv7.swift` |
| NEXT-IOS-2 | URLSession transport with retry / drop semantics | Done — `Sources/AdfiniaSDK/Transport.swift` |
| NEXT-IOS-3 | UserDefaults persistence (identity + queue) | Done — `Sources/AdfiniaSDK/KVStore.swift`, `IdentityStore.swift`, `EventQueue.swift` |
| NEXT-IOS-4 | Exponential backoff scheduler (`DispatchSourceTimer`) | Done — `Sources/AdfiniaSDK/EventQueue.swift` |
| NEXT-IOS-7 | XCTest coverage at parity with web SDK | Done — UUIDv7Tests / IdentityStoreTests / EventQueueTests / TransportTests / AdfiniaSDKTests |

## Still open

| ID | Title | Notes |
|----|-------|-------|
| NEXT-IOS-5 | CocoaPods Podspec | Lower priority than SPM; enterprise teams sometimes ask. Add `AdfiniaSDK.podspec` once SPM publish is verified. |
| NEXT-IOS-6 | Background-task handling | `BGProcessingTask` integration for tenants who need guaranteed flushes during long background windows. Default behaviour is "flush on next foreground". |
| NEXT-IOS-8 | Example app | SwiftUI demo under `Examples/SwiftUIDemo/` exercising init / identify / track / screen / alias / reset / consent toggle. Helps Apple App Review and customer onboarding. |
| NEXT-IOS-9 | ATT integration recipe | Doc-only — currently sketched in README under "App Tracking Transparency". Expand into a standalone walkthrough once the example app lands. |

## Open against the parent SDKs round

- **SwiftPM publish** (`US-SDK-PUBLISH-001`): blocked on the
  `github.com/infinia-net/adfinia-ios-sdk` public repo. The code is
  ready to tag `v0.2.0` the moment that repo exists.
- **Real backend smoke** — once `/api/v1/track` + `/api/v1/identify` are
  reachable in a staging environment (AGENT-CDP-IDENTITY), wire an
  end-to-end integration test that posts a real event from this SDK.
