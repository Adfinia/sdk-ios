// Internal — wire format. Matches @adfinia/sdk-web byte-for-byte so the
// /api/v1/track + /api/v1/identify endpoints don't need a per-platform shim.

import Foundation

enum AdfiniaPayloadType: String, Codable {
    case track, identify, page, screen, alias
}

struct AdfiniaPayload {
    let type: AdfiniaPayloadType
    let event: String?
    let customerId: String?
    let anonymousId: String
    let previousId: String?
    let properties: AdfiniaProperties?
    let traits: AdfiniaTraits?
    let sentAt: Date
    let messageId: String

    init(
        type: AdfiniaPayloadType,
        event: String?,
        customerId: String?,
        anonymousId: String,
        previousId: String?,
        properties: AdfiniaProperties?,
        traits: AdfiniaTraits?
    ) {
        self.type = type
        self.event = event
        self.customerId = customerId
        self.anonymousId = anonymousId
        self.previousId = previousId
        self.properties = properties
        self.traits = traits
        self.sentAt = Date()
        self.messageId = UUID().uuidString
    }
}
