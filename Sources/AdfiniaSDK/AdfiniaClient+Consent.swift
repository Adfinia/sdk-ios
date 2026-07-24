// AdfiniaClient consent API - write-only, per-channel consent. Split out of
// AdfiniaClient.swift so that file stays within SwiftLint's file_length limit.
// This is an extension in the same module, so behaviour is byte-for-byte
// unchanged from when it lived in AdfiniaClient.swift.
//
// Mirrors the web SDK's consent surface. See AdfiniaClient.swift for the core.

import Foundation

// MARK: - Write-only consent API

extension AdfiniaClient {
    /// Record a consent decision for one or more channels. Write-only: the
    /// SDK key can set consent but never read it back (there is intentionally
    /// no getConsent()).
    ///
    /// Channels are OPEN strings, not an enum: the backend owns the
    /// valid-channel registry (email/whatsapp/sms/push today, extensible to
    /// rcs/voice/app_notification later), so whatever value is passed is
    /// forwarded (trim + lowercase only) and future backend channels work
    /// with no SDK release. Unknown channels are never rejected.
    ///
    /// Emits exactly ONE event:
    ///   track("consent_updated", properties: ["channels": [...], "status": status])
    /// where `channels` is ALWAYS an array on the wire, even for one channel.
    ///
    /// Never throws. An invalid `status` logs a one-time debug message and
    /// sends nothing; an empty channel list is a soft no-op.
    public func setConsent(_ channels: [String], status: String) {
        if status != "opted_in" && status != "opted_out" {
            stateLock.lock(); let alreadyLogged = consentStatusLogged; consentStatusLogged = true; stateLock.unlock()
            if !alreadyLogged {
                log(
                    "setConsent() called with invalid status \"\(status)\" - "
                    + "expected \"opted_in\" or \"opted_out\"; nothing sent"
                )
            }
            return
        }
        let list = channels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !list.isEmpty else {
            log("setConsent() called with no channels - nothing sent")
            return
        }
        // Reuse the standard track path: guard (init + consent gate), enqueue,
        // transport. The backend ConsentSink consumes "consent_updated".
        track("consent_updated", properties: ["channels": list, "status": status])
    }

    /// setConsent for a single channel.
    public func setConsent(_ channel: String, status: String) {
        setConsent([channel], status: status)
    }

    /// Shorthand for setConsent(channels, status: "opted_in").
    public func optIn(_ channels: [String]) {
        setConsent(channels, status: "opted_in")
    }

    /// Shorthand for setConsent(channel, status: "opted_in").
    public func optIn(_ channel: String) {
        setConsent([channel], status: "opted_in")
    }

    /// Shorthand for setConsent(channels, status: "opted_out").
    public func optOut(_ channels: [String]) {
        setConsent(channels, status: "opted_out")
    }

    /// Shorthand for setConsent(channel, status: "opted_out").
    public func optOut(_ channel: String) {
        setConsent([channel], status: "opted_out")
    }
}
