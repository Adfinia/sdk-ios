# AdfiniaSDK iOS — next implementation steps

Round 2 (2026-05-20) landed the real implementation. `NEXT-IOS-1..4` and
`NEXT-IOS-7` are now done. Remaining items are platform-niceties + the
final publish step.

## Done in v1.2.0 (2026-07-24) — push + inbox

| ID | Title | Status |
|----|-------|--------|
| NEXT-IOS-10 | Native push registration (`registerForPush`/`unregisterForPush` + `requestPushAuthorization`) | Done — `Sources/AdfiniaSDK/PushRegistration.swift`. Mirrors RN `pushNative.ts` payload -> `POST /api/v1/push/register`. Emits `push_registered`. |
| NEXT-IOS-11 | In-app notification inbox (`Adfinia.notifications` list / markRead / markAllRead / SSE stream) | Done — `Sources/AdfiniaSDK/Notifications.swift` + `ControlPlaneClient.swift`. Typed `AdfiniaNotification` mirrors backend `InboxNotification`. |

### ⚠ Backend follow-up flagged (NOT fixed here — outside sdk-ios scope)

The register endpoint contract diverges from what the SDK (and the RN SDK) send:

1. **`POST /api/v1/push/register` does NOT persist to `device_tokens`.** In
   `api/internal/activation/push/`, this route is served by `Handler.registerDevice`
   -> `Dispatcher.RegisterDevice` (dispatcher.go), which only logs
   `"device token registered (persistence deferred)"` and returns 201 — it never
   writes a row. The APNs/FCM providers' `RegisterDevice` are also log-only. The
   `device_tokens` table (the APNs fan-out source) is populated ONLY by the
   separate `POST /api/v1/device-tokens` handler (`device_tokens_handler.go` ->
   `PGRepository.Register`). So a device that registers via the SDK will not
   receive push until the register route is pointed at the repository.
2. **Field + validation mismatch.** The backend `RegisterRequest` (dispatcher.go)
   is `{token, platform, contact_id}` with `contact_id` REQUIRED, and the handler
   decodes with `DisallowUnknownFields()`. The SDK payload (matching RN) sends
   `device_id`, `app_version`, `customer_id`, `anonymous_id` and no `contact_id`,
   so the current handler would 400 on unknown fields / missing `contact_id`.

   Backend action (file as an api story): make `/api/v1/push/register` (a) accept
   the SDK/RN body (`device_id`/`app_version`/identity bag, optional `contact_id`),
   (b) resolve the contact from the identity bag, and (c) persist to `device_tokens`
   via the repository so the fan-out has a row. Until then iOS/RN push registration
   is a no-op server-side.

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
