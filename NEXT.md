# AdfiniaSDK iOS — next implementation steps

| ID | Title | Notes |
|----|-------|-------|
| NEXT-IOS-1 | UUIDv7 generator | Swap `UUID().uuidString` (UUIDv4) for a UUIDv7 implementation matching the web SDK's monotonic-counter logic. |
| NEXT-IOS-2 | Real URLSession transport | POST `{batch}` to `/api/v1/track` + `/api/v1/identify`. Bearer auth. 5xx → retry, 4xx → drop. Currently a no-op. |
| NEXT-IOS-3 | UserDefaults persistence | Suite `com.adfinia.sdk`. Keys `adfinia.identity` + `adfinia.queue`. Survive cold-start. |
| NEXT-IOS-4 | Exponential backoff scheduler | Use a `Timer` (or async sleep loop) tied to app foreground state. Pause when background expiration is imminent. |
| NEXT-IOS-5 | CocoaPods Podspec | Add `AdfiniaSDK.podspec`. Less important than SPM but still requested by enterprise teams. |
| NEXT-IOS-6 | Background-task handling | Use `BGProcessingTask` to flush during scheduled background windows. |
| NEXT-IOS-7 | XCTest coverage to parity with web | Mirror `client.test.ts` + `queue.test.ts` + `identity.test.ts` tests in XCTest. |
| NEXT-IOS-8 | Example app | A minimal SwiftUI app under `Examples/SwiftUIDemo/` exercising init + identify + track + screen + alias + reset. |
| NEXT-IOS-9 | ATT integration recipe | Doc-only: how to gate the SDK on the App Tracking Transparency dialog. |
