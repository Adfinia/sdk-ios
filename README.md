# AdfiniaSDK (iOS / Swift)

Official Adfinia SDK for iOS, macOS, tvOS, and watchOS. Same public surface as `@adfinia/sdk-web` — if you've integrated the web SDK, you already know this one.

- First-party event ingest (`track`, `identify`, `screen`).
- UUIDv7 message IDs, time-ordered for server-side sorting.
- Batched POSTs (5 seconds or 50 events, whichever fires first).
- Exponential-backoff retries on 5xx + network failures (1s → 30s cap).
- `UserDefaults`-backed offline queue — survives cold-start, drains on next launch.
- Consent gate: SDK no-ops until your `consent` closure returns `true`.
- Thread-safe via a dedicated `DispatchQueue`; safe to call from any thread.
- Pure Swift, zero third-party dependencies.

---

## Install

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** and paste:

```
https://github.com/Adfinia/sdk-ios
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Adfinia/sdk-ios", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AdfiniaSDK", package: "sdk-ios")
    ])
]
```

### CocoaPods

```ruby
pod 'Adfinia', '~> 1.0'
```

Both channels resolve from the same Git tag (`sdk-ios-v1.0.0`).

---

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
Adfinia.identify("cust_42", traits: ["plan": "growth", "country": "AE"])

Adfinia.track("Order Completed", properties: [
    "order_id": "o_123",
    "total": 49.99,
    "currency": "AED"
])

Adfinia.screen("Pricing", properties: ["tier_highlighted": "growth"])
Adfinia.reset()

Task { await Adfinia.flush() }
```

---

## API reference

| Method | Notes |
|--------|-------|
| `Adfinia.initialize(config)` | One-shot. Subsequent calls are ignored. |
| `Adfinia.identify(customerId, traits?)` | Customer-id form. |
| `Adfinia.identify(arg, traits?)` | Struct form (`AdfiniaIdentifyArg`). |
| `Adfinia.track(event, properties?)` | Event-name + props. |
| `Adfinia.screen(name?, properties?)` | Mobile analogue of `page()`. |
| `Adfinia.setConsent(channels, status:)` | Write-only consent. `channels` is `[String]` (or a single `String` overload); `status` is `"opted_in"` or `"opted_out"`. Channels are open strings (not an enum) - the backend owns the valid-channel registry. Emits one `consent_updated` event with `channels` always an array. No read method by design. |
| `Adfinia.optIn(channels)` | Shorthand for `setConsent(channels, status: "opted_in")`. |
| `Adfinia.optOut(channels)` | Shorthand for `setConsent(channels, status: "opted_out")`. |
| `Adfinia.alias(newId, previousId?)` | Deprecated (1.1.0); no-op. Anonymous sessions are promoted automatically by `identify()`. |
| `Adfinia.reset()` | Logout — mints a new anonymous_id. |
| `Adfinia.flush()` | `async`. Returns when the in-flight batch resolves. |
| `Adfinia.registerForPush(deviceToken:)` | Register the APNs device token (`Data`) from the app-delegate callback. Hex-encodes + `POST /push/register`; emits `push_registered`. |
| `Adfinia.unregisterForPush(deviceToken:)` | Remove the token (logout / notifications-off). |
| `Adfinia.requestPushAuthorization(options:completion:)` | Optional convenience prompt via `UNUserNotificationCenter`. Token-in path is primary. |
| `Adfinia.notifications.list(status:)` | In-app inbox page. `status` is `.all` / `.unread` / `.read`. |
| `Adfinia.notifications.markRead(_:)` | Mark one notification read. |
| `Adfinia.notifications.markAllRead()` | Mark all unread read; returns the count. |
| `Adfinia.notifications.stream()` | Live SSE `AsyncStream<AdfiniaNotification>` (iOS 15+). |

### `AdfiniaConfig`

```swift
AdfiniaConfig(
    writeKey: "pk_live_...",                       // required
    host: "https://api.adfinia.com",               // override for self-hosted
    debug: false,
    consent: { /* return Bool */ },
    flushAt: 50,
    flushIntervalSeconds: 5,
    maxQueueSize: 1000
)
```

---

## Push notifications

The SDK forwards the APNs device token your app receives — it does **not** link a
push entitlement itself, so adding the SDK never forces Push Notifications
capability on your target. Enable the capability in your app when you want push,
then hand the token to the SDK from the app-delegate callback:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Adfinia.registerForPush(deviceToken: deviceToken)
}
```

To have the SDK prompt for permission and trigger registration for you:

```swift
Adfinia.requestPushAuthorization { granted, _ in
    // On grant the SDK calls registerForRemoteNotifications(); your
    // didRegister callback then fires and you forward the token above.
}
```

On success the SDK `POST`s `{token, platform:"ios", device_id, app_version,
customer_id, anonymous_id}` to `/api/v1/push/register` (the same payload shape as
the React Native SDK) and emits a `push_registered` event. Call
`Adfinia.unregisterForPush(deviceToken:)` on logout.

---

## In-app notification inbox

`Adfinia.notifications` reads the tenant's in-app messages for the current
contact (resolved from `customer_id`, else `anonymous_id`):

```swift
let result = await Adfinia.notifications.list(status: .unread)
if case .success(let page) = result {
    for n in page.data { print(n.title, n.body, n.read) }
    // page.nextCursor / page.hasMore drive pagination
}

await Adfinia.notifications.markRead("notif_id")
await Adfinia.notifications.markAllRead()

// Live updates (iOS 15+):
for await notification in Adfinia.notifications.stream() {
    // render the incoming notification
}
```

---

## Consent integration

The SDK runs through a consent gate on every public method. While `consent` returns `false`, the SDK silently no-ops — no buffering, no network. When the gate flips to `true`, the next call proceeds normally; there's no replay of previously dropped events.

If the user revokes consent later, call `Adfinia.reset()` to mint a new anonymous_id — that disconnects subsequent events from the prior session.

Full consent-architecture write-up: [docs.adfinia.com/user-guide/consent](https://docs.adfinia.com/user-guide/consent).

---

## Platform targets

| Target | Minimum version |
|--------|-----------------|
| iOS | 16.0+ |
| macOS | 13.0+ |
| tvOS | 16.0+ |
| watchOS | 9.0+ |
| Swift | 5.9+ |
| Xcode | 15+ |

---

## Looking for the full integration guide?

[docs.adfinia.com/user-guide/sdk-integration#ios](https://docs.adfinia.com/user-guide/sdk-integration#ios) — covers ATT integration, ATS exceptions, background flushes, privacy disclosures for App Store submission, and self-hosted ingest configuration.

---

## Privacy disclosures

The SDK only sends data you explicitly track. It does **not**:

- Read the device IDFA / IDFV.
- Use SKAdNetwork.
- Read clipboard / contacts / photos / location.
- Collect any device identifier beyond the SDK-minted `anonymous_id` stored in `UserDefaults`.

The `anonymous_id` is a UUIDv7 minted on first launch and persisted to a dedicated `UserDefaults` suite (`com.adfinia.sdk`). It survives app relaunches but does not survive a re-install or a call to `reset()`.

---

## Issues + contributing

- Bugs and feature requests: [github.com/Adfinia/sdk-ios/issues](https://github.com/Adfinia/sdk-ios/issues)
- Contributing guide: [CONTRIBUTING.md](./CONTRIBUTING.md)
- Email: engineering@adfinia.com

---

## License

MIT — see [LICENSE](./LICENSE).
