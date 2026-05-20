// Single source of truth for the library identifier emitted in every
// event's `context.library.name` / `context.library.version` block. Kept
// in sync with the npm + Maven + pub.dev packages on release.

import Foundation

enum AdfiniaVersion {
    static let libraryName = "adfinia-sdk-ios"
    static let libraryVersion = "0.2.0"
}
