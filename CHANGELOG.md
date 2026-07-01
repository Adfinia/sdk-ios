# AdfiniaSDK (iOS) changelog

All notable changes to the official Adfinia iOS SDK land here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The SDK
follows [semver](https://semver.org/) starting at 1.0.0.

## [Unreleased]

### Fixed
- Default ingest `host` is now `https://api.adfinia.com` (was
  `https://events.adfinia.com`, an unprovisioned domain that failed at DNS so
  events were dropped silently). Callers passing an explicit `host` are
  unaffected. Brings iOS in line with web and React Native.

### Changed
- Transport routes a lone track-like event through `POST /api/v1/track/batch`
  (a 1-element batch) instead of the single-event `POST /api/v1/track`. The
  single-event path does not stamp the event environment from the
  authenticating API key (it defaults to `live`), so a `adf_test_` key's solo
  event would be mis-tagged and leak into live analytics; the batch endpoint
  stamps it from the key. A lone `identify` still uses single
  `POST /api/v1/identify` (it resolves `customer_id` and carries no environment
  tag). Mirrors `@adfinia/sdk-web` 1.3.1 + `@adfinia/sdk-react-native` 1.0.1.
  Folds into the first published release (1.0.0 is not yet on CocoaPods/SPM).

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
