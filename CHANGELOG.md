# AdfiniaSDK (iOS) changelog

All notable changes to the official Adfinia iOS SDK land here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The SDK
follows [semver](https://semver.org/) starting at 1.0.0.

## [1.0.0-rc.1] — 2026-05-22

First release candidate. The wire surface and public API are now frozen
for the 1.0 line — only backwards-compatible additions land after this.

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
- Library version bumped `0.2.0 → 1.0.0-rc.1`.
- `AdfiniaVersion` gains the `sdkVersionHeader` computed property
  (`"adfinia-sdk-ios@<libraryVersion>"`).

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
