// Per-event context block builder. Mirrors `sdks/web/src/context.ts`
// but with Apple-platform fields (os.name = "iOS", app bundle info,
// device model) where the web SDK would put page / referrer.

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(WatchKit)
import WatchKit
#endif

enum AdfiniaContextBuilder {
    static func build() -> AdfiniaContext {
        var ctx = AdfiniaContext(
            library: AdfiniaLibraryInfo(
                name: AdfiniaVersion.libraryName,
                version: AdfiniaVersion.libraryVersion
            )
        )

        ctx.locale = Locale.current.identifier
        ctx.timezone = TimeZone.current.identifier

        // OS — use the host platform's reported name + version where we can.
        var os = AdfiniaOSContext()
        #if os(iOS)
        os.name = "iOS"
        #elseif os(macOS)
        os.name = "macOS"
        #elseif os(tvOS)
        os.name = "tvOS"
        #elseif os(watchOS)
        os.name = "watchOS"
        #else
        os.name = "Apple"
        #endif
        os.version = osVersionString()
        ctx.os = os

        // App — read from the host's Info.plist when available.
        var app = AdfiniaAppContext()
        if let info = Bundle.main.infoDictionary {
            app.name = info["CFBundleName"] as? String
            app.version = info["CFBundleShortVersionString"] as? String
            app.build = info["CFBundleVersion"] as? String
        }
        if app.name != nil || app.version != nil || app.build != nil {
            ctx.app = app
        }

        // Device — model + manufacturer.
        var device = AdfiniaDeviceContext()
        device.manufacturer = "Apple"
        #if os(iOS) || os(tvOS)
        device.model = UIDevice.current.model
        #elseif os(watchOS)
        device.model = WKInterfaceDevice.current().model
        #else
        device.model = macHardwareModel()
        #endif
        ctx.device = device

        return ctx
    }

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion == 0 {
            return "\(v.majorVersion).\(v.minorVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    #if os(macOS)
    private static func macHardwareModel() -> String? {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
    #endif
}

/// Flatten the context block into the `[String: String]` shape the
/// `/api/v1/track` + `/api/v1/identify` endpoints accept.
func flattenContext(_ ctx: AdfiniaContext, messageId: String, sdkEventType: String) -> [String: String] {
    var out: [String: String] = [:]
    out["library.name"] = ctx.library.name
    out["library.version"] = ctx.library.version
    out["message_id"] = messageId
    out["sdk_event_type"] = sdkEventType
    if let v = ctx.locale { out["locale"] = v }
    if let v = ctx.timezone { out["timezone"] = v }
    if let v = ctx.os?.name { out["os.name"] = v }
    if let v = ctx.os?.version { out["os.version"] = v }
    if let v = ctx.app?.name { out["app.name"] = v }
    if let v = ctx.app?.version { out["app.version"] = v }
    if let v = ctx.app?.build { out["app.build"] = v }
    if let v = ctx.device?.model { out["device.model"] = v }
    if let v = ctx.device?.manufacturer { out["device.manufacturer"] = v }
    return out
}
