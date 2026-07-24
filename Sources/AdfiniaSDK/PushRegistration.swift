// Native push registration. The iOS counterpart to the React Native SDK's
// `pushNative.ts` — SAME endpoint + payload, adapted to Swift ergonomics:
//
//   this SDK -> POST   /api/v1/push/register        { token, platform, device_id, app_version, <identity> }
//            -> DELETE  /api/v1/push/register/{token}
//
// Flow: the host app receives the APNs device token in
// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` as a
// `Data` blob, hands it to `Adfinia.registerForPush(deviceToken:)`, and the
// SDK hex-encodes it (APNs tokens are canonically the lowercase hex string),
// attaches the current identity bag, and POSTs it. The backend stores it in
// `device_tokens` and dispatches via APNs. On success the SDK emits a
// `push_registered` track event so the registration shows up in analytics.
//
// The token-in path is primary and has NO dependency on a push entitlement at
// SDK build time — the SDK never links the APNs entitlement, it only forwards
// the token the host obtained. `requestPushAuthorization` is a convenience
// wrapper over UNUserNotificationCenter for teams that want the SDK to prompt;
// it is compiled only where UserNotifications is available and is never on the
// critical path.

import Foundation
#if canImport(UserNotifications) && !os(tvOS)
import UserNotifications
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Outcome of a push registration / unregistration call. `ok` is the headline;
/// `reason` carries a stable machine-readable failure string for logs.
public struct AdfiniaPushRegistrationResult: Equatable {
    // `ok` is the headline flag and is part of the public API (renaming it
    // would be a source-breaking change), so the min-identifier-length rule
    // is suppressed for this one property only.
    // swiftlint:disable:next identifier_name
    public let ok: Bool
    /// The hex-encoded token that was (un)registered, when known.
    public let token: String?
    /// One of `not_initialised` | `empty_token` | `post_failed` on failure;
    /// nil on success.
    public let reason: String?

    static func success(_ token: String) -> AdfiniaPushRegistrationResult {
        AdfiniaPushRegistrationResult(ok: true, token: token, reason: nil)
    }

    static func failure(_ reason: String, token: String? = nil) -> AdfiniaPushRegistrationResult {
        AdfiniaPushRegistrationResult(ok: false, token: token, reason: reason)
    }
}

/// Wire payload for `POST /api/v1/push/register`. Mirrors the React Native
/// SDK's body: `token` + `platform` + `device_id` + `app_version` + identity.
struct AdfiniaPushRegisterWire: Encodable {
    let token: String
    let platform: String
    let deviceId: String
    let appVersion: String?
    let customerId: String?
    let anonymousId: String

    // CodingKeys map each field back to the exact snake_case JSON keys the
    // API expects, so the serialised bytes are unchanged; only the Swift
    // property names are camelCase.
    enum CodingKeys: String, CodingKey {
        case token
        case platform
        case deviceId = "device_id"
        case appVersion = "app_version"
        case customerId = "customer_id"
        case anonymousId = "anonymous_id"
    }
}

public extension AdfiniaClient {
    /// Hex-encode an APNs device-token blob into the lowercase hex string the
    /// APNs / backend contract expects. Exposed so hosts that already hold a
    /// hex string can bypass it via ``registerForPush(hexToken:completion:)``.
    static func hexEncode(deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// Register the APNs device token the host received in
    /// `didRegisterForRemoteNotificationsWithDeviceToken`. Fire-and-forget:
    /// the network call runs on a detached Task. Pass `completion` to observe
    /// the outcome. Emits a `push_registered` track event on success.
    func registerForPush(
        deviceToken: Data,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        registerForPush(hexToken: Self.hexEncode(deviceToken: deviceToken), completion: completion)
    }

    /// Register a pre-hex-encoded APNs token.
    func registerForPush(
        hexToken: String,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        Task { [weak self] in
            let result = await self?.performPushRegister(hexToken: hexToken)
                ?? .failure("not_initialised")
            completion?(result)
        }
    }

    /// Async variant of registration for callers already in an async context.
    @discardableResult
    func performPushRegister(hexToken: String) async -> AdfiniaPushRegistrationResult {
        guard isInitialised, let transport = controlPlaneTransport else {
            debugLog("registerForPush() called before initialize() — dropped")
            return .failure("not_initialised")
        }
        let token = hexToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            debugLog("registerForPush() called with an empty token — dropped")
            return .failure("empty_token")
        }
        guard let identity = pushIdentityBag() else {
            return .failure("not_initialised")
        }

        let wire = AdfiniaPushRegisterWire(
            token: token,
            platform: "ios",
            // The anonymous_id is device/install-scoped; it doubles as a stable
            // device_id so the backend can de-dupe tokens per device (matches RN).
            deviceId: identity.anonymousId,
            appVersion: AdfiniaAppInfo.version(),
            customerId: identity.customerId,
            anonymousId: identity.anonymousId
        )

        let body: Data
        do {
            body = try JSONEncoder().encode(wire)
        } catch {
            return .failure("post_failed", token: token)
        }

        let res = await transport.post("/api/v1/push/register", body: body)
        guard res.ok else {
            debugLog("registerForPush() POST failed — status \(res.status.map(String.init) ?? "nil")")
            return .failure("post_failed", token: token)
        }

        // Analytics breadcrumb — mirrors the RN SDK. Flows through the standard
        // guard / enqueue / transport path.
        track("push_registered", properties: ["platform": "ios"])
        debugLog("registerForPush() ok")
        return .success(token)
    }

    /// Unregister the APNs device token (e.g. on logout / notifications-off).
    func unregisterForPush(
        deviceToken: Data,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        unregisterForPush(hexToken: Self.hexEncode(deviceToken: deviceToken), completion: completion)
    }

    /// Unregister a pre-hex-encoded token.
    func unregisterForPush(
        hexToken: String,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        Task { [weak self] in
            let result = await self?.performPushUnregister(hexToken: hexToken)
                ?? .failure("not_initialised")
            completion?(result)
        }
    }

    /// Async variant of unregistration.
    @discardableResult
    func performPushUnregister(hexToken: String) async -> AdfiniaPushRegistrationResult {
        guard isInitialised, let transport = controlPlaneTransport else {
            debugLog("unregisterForPush() called before initialize() — dropped")
            return .failure("not_initialised")
        }
        let token = hexToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure("empty_token") }

        // Path-segment encode: APNs hex tokens are already URL-safe, but guard
        // against a caller passing an arbitrary provider token.
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        let res = await transport.delete("/api/v1/push/register/\(encoded)")
        guard res.ok else {
            debugLog("unregisterForPush() DELETE failed — status \(res.status.map(String.init) ?? "nil")")
            return .failure("post_failed", token: token)
        }
        debugLog("unregisterForPush() ok")
        return .success(token)
    }
}

// MARK: - Authorization convenience (UserNotifications)

#if canImport(UserNotifications) && !os(tvOS)
public extension AdfiniaClient {
    /// Request notification authorization from the user via
    /// UNUserNotificationCenter, then (on grant) ask the system to register for
    /// remote notifications on the main thread. This is a CONVENIENCE — the
    /// primary integration is the token-in path (`registerForPush(deviceToken:)`
    /// from the app-delegate callback). Hosts that manage their own permission
    /// prompt can ignore this entirely.
    ///
    /// The SDK does not link the APNs entitlement; `registerForRemoteNotifications`
    /// is a no-op in a target without push capability, so this never crashes a
    /// build that hasn't enabled Push Notifications.
    func requestPushAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound],
        completion: (@Sendable (Bool, Error?) -> Void)? = nil
    ) {
        track("notification_permission_prompted", properties: ["channel": "native_push"])
        UNUserNotificationCenter.current().requestAuthorization(options: options) { [weak self] granted, error in
            if granted {
                self?.track("notification_permission_granted", properties: ["channel": "native_push"])
                #if canImport(UIKit) && !os(watchOS)
                Task { @MainActor in
                    UIApplication.shared.registerForRemoteNotifications()
                }
                #endif
            } else {
                self?.track("notification_permission_denied", properties: ["channel": "native_push"])
            }
            completion?(granted, error)
        }
    }
}
#endif

// MARK: - Static forwarders

public extension Adfinia {
    /// Register the APNs device token from
    /// `didRegisterForRemoteNotificationsWithDeviceToken`. Emits `push_registered`.
    static func registerForPush(
        deviceToken: Data,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        shared.registerForPush(deviceToken: deviceToken, completion: completion)
    }

    /// Register a pre-hex-encoded APNs token.
    static func registerForPush(
        hexToken: String,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        shared.registerForPush(hexToken: hexToken, completion: completion)
    }

    /// Unregister the APNs device token (logout / notifications-off).
    static func unregisterForPush(
        deviceToken: Data,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        shared.unregisterForPush(deviceToken: deviceToken, completion: completion)
    }

    /// Unregister a pre-hex-encoded token.
    static func unregisterForPush(
        hexToken: String,
        completion: (@Sendable (AdfiniaPushRegistrationResult) -> Void)? = nil
    ) {
        shared.unregisterForPush(hexToken: hexToken, completion: completion)
    }
}

#if canImport(UserNotifications) && !os(tvOS)
public extension Adfinia {
    /// Convenience notification-authorization prompt. See
    /// ``AdfiniaClient/requestPushAuthorization(options:completion:)``.
    static func requestPushAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound],
        completion: (@Sendable (Bool, Error?) -> Void)? = nil
    ) {
        shared.requestPushAuthorization(options: options, completion: completion)
    }
}
#endif
