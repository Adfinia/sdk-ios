# AdfiniaSDK (iOS / Swift)

Official Adfinia SDK for iOS, macOS, tvOS, and watchOS. Same public surface
as `@adfinia/sdk-web` — if you've integrated the web SDK, you already know
this one.

> **Status:** skeleton. The public API is stable and matches the web SDK
> shape. Network transport, UserDefaults persistence, and exponential
> backoff are stubbed and tracked in [`NEXT.md`](./NEXT.md). Do not ship
> to production yet.

## Install

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** and paste:

```
https://github.com/infinia-net/adfinia-ios-sdk
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/infinia-net/adfinia-ios-sdk", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AdfiniaSDK", package: "adfinia-ios-sdk")
    ])
]
```

### CocoaPods (planned)

A Podspec lands with NEXT-IOS-5.

## Quickstart

```swift
import AdfiniaSDK

// Typically in your AppDelegate / @main App init:
Adfinia.initialize(AdfiniaConfig(
    writeKey: "pk_live_your_public_key",
    debug: true,
    consent: { UserDefaults.standard.bool(forKey: "analytics_consent") }
))

// Identify
Adfinia.identify("cust_42", traits: ["plan": "growth"])

// Track
Adfinia.track("Order Completed", properties: [
    "order_id": "o_123",
    "total": 49.99,
    "currency": "AED"
])

// Screen
Adfinia.screen("Pricing")

// Alias on signup
Adfinia.alias("cust_42")

// Reset on logout
Adfinia.reset()

// Optional explicit flush
Task { await Adfinia.flush() }
```

## API Surface

| Method | Notes |
|--------|-------|
| `Adfinia.initialize(config)` | One-shot. Subsequent calls are ignored. |
| `Adfinia.identify(customerId, traits?)` | Customer-id form. |
| `Adfinia.identify(arg, traits?)` | Object form (`AdfiniaIdentifyArg`). |
| `Adfinia.track(event, properties?)` | Event-name + props. |
| `Adfinia.screen(name?, properties?)` | Mobile analogue of `page()`. |
| `Adfinia.alias(newId, previousId?)` | Link anonymous → known. |
| `Adfinia.reset()` | Logout — mints new anonymous_id. |
| `Adfinia.flush()` | `async`, returns when in-flight batch resolves. |

## Privacy disclosures

The SDK only sends data you explicitly track. It does **not**:

- Read the device IDFA / IDFV.
- Use SKAdNetwork.
- Read clipboard / contacts / photos.

For App Tracking Transparency: if your app integrates ATT, gate
`Adfinia.initialize(...)` (or your `consent` callback) on the
`ATTrackingManager.trackingAuthorizationStatus == .authorized` check. The
SDK won't ask for the prompt itself — that's your app's call.

## Platform support

- iOS 16+
- macOS 13+
- tvOS 16+
- watchOS 9+

## License

MIT — see [LICENSE](./LICENSE).
