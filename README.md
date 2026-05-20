# AdfiniaSDK (iOS / Swift)

Official Adfinia SDK for iOS, macOS, tvOS, and watchOS. Same public surface
as `@adfinia/sdk-web` — if you've integrated the web SDK, you already know
this one.

- First-party event ingest (`track`, `identify`, `screen`, `alias`).
- UUIDv7 message IDs, time-ordered for server-side sorting.
- Batched POSTs to `/api/v1/track` + `/api/v1/identify` (5 seconds or
  50 events, whichever fires first).
- Exponential-backoff retries on 5xx + network failures (1s → 30s cap).
- Permanent drop on 4xx with a debug-log breadcrumb.
- UserDefaults-backed offline queue — survives cold-start, drains on next
  launch.
- Consent gate: SDK no-ops until your `consent` closure returns `true`.
- Thread-safe via a dedicated `DispatchQueue`; safe to call from any thread.
- Pure Swift, zero third-party dependencies.

## Install

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** and paste:

```
https://github.com/infinia-net/adfinia-ios-sdk
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/infinia-net/adfinia-ios-sdk", from: "0.2.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AdfiniaSDK", package: "adfinia-ios-sdk")
    ])
]
```

### CocoaPods

Tracked under `NEXT-IOS-5`. SPM is the recommended distribution channel and
ships first; the Podspec lands once the SwiftPM publish is verified in
production.

## Quickstart

### SwiftUI

```swift
import SwiftUI
import AdfiniaSDK

@main
struct MyApp: App {
    init() {
        Adfinia.initialize(AdfiniaConfig(
            writeKey: "pk_live_your_public_key",
            debug: false,
            consent: { UserDefaults.standard.bool(forKey: "analytics_consent") }
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### UIKit

```swift
import UIKit
import AdfiniaSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: ...) -> Bool {
        Adfinia.initialize(AdfiniaConfig(
            writeKey: "pk_live_your_public_key",
            consent: { UserDefaults.standard.bool(forKey: "analytics_consent") }
        ))
        return true
    }
}
```

### Tracking events

```swift
// Tie the device to a known customer (typically right after login).
Adfinia.identify("cust_42", traits: ["plan": "growth", "country": "AE"])

// Or pass the full struct form.
Adfinia.identify(.object(
    customerId: "cust_42",
    anonymousId: nil,
    traits: ["plan": "growth"]
))

// Track behaviour.
Adfinia.track("Order Completed", properties: [
    "order_id": "o_123",
    "total": 49.99,
    "currency": "AED"
])

// Mobile analogue of web's page() — fires on screen change.
Adfinia.screen("Pricing", properties: ["tier_highlighted": "growth"])

// Link a freshly-signed-up account to a prior anonymous session.
Adfinia.alias("cust_42")

// On logout — clears customer_id + traits, mints a fresh anonymous_id.
Adfinia.reset()

// Force an immediate flush (e.g. before backgrounding for a known long
// stretch). Awaits the in-flight batch.
Task { await Adfinia.flush() }
```

## API surface

| Method | Notes |
|--------|-------|
| `Adfinia.initialize(config)` | One-shot. Subsequent calls are ignored. |
| `Adfinia.identify(customerId, traits?)` | Customer-id form. |
| `Adfinia.identify(arg, traits?)` | Struct form (`AdfiniaIdentifyArg`). |
| `Adfinia.track(event, properties?)` | Event-name + props. |
| `Adfinia.screen(name?, properties?)` | Mobile analogue of `page()`. |
| `Adfinia.alias(newId, previousId?)` | Link anonymous → known customer. |
| `Adfinia.reset()` | Logout — mints a new anonymous_id. |
| `Adfinia.flush()` | `async`. Returns when the in-flight batch resolves. |
| `Adfinia.shared` | Underlying ``AdfiniaClient`` if you need direct access. |

## Configuration

```swift
AdfiniaConfig(
    writeKey: "pk_live_...",                       // required
    host: "https://events.adfinia.com",            // override for self-hosted
    debug: false,                                  // prints SDK internals to stdout
    consent: { /* return Bool */ },                // gate every API call
    flushAt: 50,                                   // immediate-flush threshold
    flushIntervalSeconds: 5,                       // background-flush cadence
    maxQueueSize: 1000                             // drop oldest past this
)
```

The defaults match the web SDK. Self-hosted tenants override `host`.

## Consent + GDPR / PDPL

The SDK runs through a consent gate on every public method. While
`consent` returns `false`, the SDK silently no-ops — no buffering, no
network. As soon as your consent callback flips to `true`, the next call
proceeds normally:

```swift
// In your app's settings screen:
@AppStorage("analytics_consent") var analyticsConsent = false

// At init:
Adfinia.initialize(AdfiniaConfig(
    writeKey: "pk_live_xxx",
    consent: { UserDefaults.standard.bool(forKey: "analytics_consent") }
))

// User flips the toggle — SDK starts ingesting immediately, no restart
// required. There's nothing to opt back out of: any events from while
// the gate was false were never created.
```

If the user revokes consent later, call `Adfinia.reset()` to mint a new
anonymous_id — that disconnects subsequent events from the prior session.

## App Tracking Transparency (ATT)

The SDK does **not** read the device IDFA / IDFV and does **not** call
SKAdNetwork. You typically do **not** need to call
`ATTrackingManager.requestTrackingAuthorization` just to use Adfinia.

If your app integrates ATT for other reasons (Meta SDK, Google's mobile
attribution, etc.), gate Adfinia's consent callback on the ATT status:

```swift
import AppTrackingTransparency
import AdfiniaSDK

Adfinia.initialize(AdfiniaConfig(
    writeKey: "pk_live_xxx",
    consent: {
        ATTrackingManager.trackingAuthorizationStatus == .authorized
    }
))
```

## App Transport Security (ATS)

The default `host` is `https://events.adfinia.com` — TLS 1.2+ with
forward secrecy, no special ATS exceptions required. Self-hosted tenants
on `http://` or a custom intranet host must declare an ATS exception in
the host app's `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>events.your-tenant.internal</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <true/>
    </dict>
  </dict>
</dict>
```

This is only needed for non-HTTPS hosts. HTTPS hosts with valid certs
work out of the box.

## Background flushes

The SDK opportunistically flushes on the next foreground if your app
exits before the 5-second window closes. There's no explicit
`UIBackgroundTaskIdentifier` use today — `BGProcessingTask` integration
is on the roadmap (`NEXT-IOS-6`) for tenants who need flush guarantees
during long background spans.

If you know you're about to background for a long time and want a clean
flush window, call `await Adfinia.flush()` from your app delegate's
`applicationDidEnterBackground` (UIKit) or `scenePhase` change
(SwiftUI) handler.

## Privacy disclosures

The SDK only sends data you explicitly track. It does **not**:

- Read the device IDFA / IDFV.
- Use SKAdNetwork.
- Read clipboard / contacts / photos / location.
- Collect any device identifier beyond the SDK-minted `anonymous_id`
  stored in `UserDefaults`.

The `anonymous_id` is a UUIDv7 minted on first launch and persisted to
a dedicated `UserDefaults` suite (`com.adfinia.sdk`). It survives app
relaunches but does not survive a re-install or a call to `reset()`.

## Platform support

- iOS 16+
- macOS 13+
- tvOS 16+
- watchOS 9+
- Swift 5.9+, Xcode 15+

## Threading

Every public method is safe to call from any thread. Internally the SDK
serialises queue mutations + flushes on a dedicated `DispatchQueue`
labelled `com.adfinia.sdk.queue`. `flush()` is `async` and returns when
the in-flight batch resolves; the rest are fire-and-forget.

## License

MIT — see [LICENSE](./LICENSE).

## Status + roadmap

- **v0.2.0** (current) — real URLSession transport, UserDefaults
  persistence, exponential-backoff retries, UUIDv7 ids, parity test
  coverage. Production-ready behaviour pending the SwiftPM repo
  provisioning (see `product/notes-from-sdks.md`).
- **NEXT** — CocoaPods Podspec, `BGProcessingTask` integration,
  SwiftUI example app, ATT integration recipe under `Examples/`. See
  [`NEXT.md`](./NEXT.md).
