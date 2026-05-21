// Single source of truth for the library identifier emitted in every
// event's `context.library.name` / `context.library.version` block AND
// in the `X-Adfinia-SDK-Version` header every HTTP request carries.
// Kept in sync with the npm + Maven + pub.dev packages on release.
//
// Header shape (server contract, see
// api/internal/identity/sdk_config_handler.go):
//
//     X-Adfinia-SDK-Version: adfinia-sdk-ios@1.0.0
//
// The server's SDKVersionMiddleware parses this header to enforce the
// minimum supported version per SDK. Below the floor → 426 Upgrade
// Required.

import Foundation

enum AdfiniaVersion {
    static let libraryName = "adfinia-sdk-ios"
    static let libraryVersion = "1.0.0"

    /// Value to send as the `X-Adfinia-SDK-Version` header.
    static var sdkVersionHeader: String {
        "\(libraryName)@\(libraryVersion)"
    }
}
