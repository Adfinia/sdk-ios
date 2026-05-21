# AdfiniaSDK (iOS) changelog

All notable changes to the official Adfinia iOS SDK land here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The SDK
follows [semver](https://semver.org/) starting at 1.0.0.

## [1.0.0] — 2026-05-22

First stable release. Same content as the dev-internal-only
`1.0.0-rc.1` build (never published to CocoaPods or tagged on GitHub);
the founder direction on 2026-05-22 was to drop the `-rc.1` suffix and
ship straight as `1.0.0`. SPM consumers resolve via the `sdk-ios-v1.0.0`
Git tag; CocoaPods consumers pull from `pod trunk push`.

### Added
- **Server-driven runtime config.** On `initialize()`, the SDK fetches
  `GET /api/v1/sdk/config` from a detached `Task` and applies
  `batch_size` + `flush_interval_ms` to the running `EventQueue`. The
  fetch is fire-and-forget — a network or 4xx error leaves the local
  defaults in place. Unknown response fields are ignored.
- **`X-Adfinia-SDK-Version` header.** Every request (batch + single
  legacy + `/sdk/config`) carries `adfinia-sdk-ios@<version>`. The
  server's version middleware returns `426 Upgrade Required` when this
  release falls below the supported floor.
- **`EventQueue.applyRemoteConfig(flushAt:flushIntervalSeconds:)`** —
  internal API the client uses to apply remote knobs without restart.
- **`Adfinia.podspec`.** CocoaPods consumers now have a published spec
  pointing at the same `Sources/AdfiniaSDK/**/*.swift` SPM uses. SPM
  remains via the `Package.swift` + Git tag.

### Changed
- Library version bumped `0.2.0 → 1.0.0`.
- `AdfiniaVersion` gains the `sdkVersionHeader` computed property
  (`"adfinia-sdk-ios@<libraryVersion>"`).

## ~~[1.0.0-rc.1] — 2026-05-22~~

~~Dev-internal release candidate. Never published to CocoaPods, never
tagged on GitHub; superseded by `1.0.0` on the same day per founder
direction. Same code, no `-rc.1` suffix on the public artifact.~~

### Notes
- No breaking changes to the public `initialize / identify / track /
  screen / alias / reset / flush` surface vs 0.2.0.
- Endpoints in use:
  - `POST /api/v1/track/batch`
  - `POST /api/v1/identify/batch`
  - `POST /api/v1/track` and `/api/v1/identify` (single-event fallback)
  - `GET /api/v1/sdk/config` (init)

## [0.2.0] — 2026-05-20

Initial Swift package alongside the web / Android / React Native /
Flutter SDK skeletons.
