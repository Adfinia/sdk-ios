# Contributing to AdfiniaSDK (iOS)

Public API parity with `@adfinia/sdk-web` is the hard rule — if you're
adding a method here, file a parallel issue against the web, Android, RN,
and Flutter SDKs.

## Local setup

```bash
git clone https://github.com/infinia-net/adfinia-ios-sdk
cd adfinia-ios-sdk
swift build
swift test
```

Or open `Package.swift` in Xcode and use the test navigator.

## Branching + PRs

Same as the web SDK — branch from `main`, prefix with `feat/`, `fix/`,
`docs/`, `chore/`. Conventional Commits in commit messages.

## Style

- Swift 5.9+, strict concurrency where it doesn't fight Foundation.
- Public types in `Sources/AdfiniaSDK/Adfinia*.swift`. Internal helpers
  stay file-private or `internal` — never `public`.
- Use `XCTest`, not Swift Testing (yet — switch when Xcode 16 is the
  minimum).

## Security

Email `security@adfinia.com`.
