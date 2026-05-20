// UUIDv7 — time-ordered, 128-bit. Spec: RFC 9562 §5.7.
//
// Mirrors `sdks/web/src/uuid.ts` so iOS and web emit comparable IDs and the
// server can sort by `message_id` without a clock-skew step.
//
// Monotonicity within the same millisecond is preserved by a 12-bit
// per-ms counter in the `rand_a` section (bits 48..59 of the UUID,
// ignoring the version nibble). This matches the "Method 1: Monotonic
// Random" pattern from RFC 9562 §6.2.

import Foundation

/// Thread-safe UUIDv7 generator. Use ``UUIDv7/generate()`` from any queue
/// — internal state is guarded by an `os_unfair_lock`-free serial lock.
enum UUIDv7 {
    // Shared state for monotonicity within the same millisecond.
    private static let lock = NSLock()
    private static var lastMs: UInt64 = 0
    private static var counter: UInt16 = 0  // 12-bit per-ms counter.

    /// Returns a canonical 36-character UUIDv7 string of the form
    /// `xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx` where the first 48 bits encode
    /// `unix_ts_ms` big-endian and the version nibble is `7`, variant `10`.
    static func generate() -> String {
        var ms = UInt64(Date().timeIntervalSince1970 * 1000.0)

        lock.lock()
        if ms == lastMs {
            counter &+= 1
            if counter > 0x0fff {
                // Counter overflow — bump the clock so the next batch lands
                // in the next ms. Extremely rare in practice.
                ms = lastMs + 1
                lastMs = ms
                counter = 0
            }
        } else {
            lastMs = ms
            counter = 0
        }
        let snapshotCounter = counter
        lock.unlock()

        // 16 bytes — 6 timestamp, 2 counter (with version), 1 variant, 7 random.
        var bytes = [UInt8](repeating: 0, count: 16)

        // First 48 bits = unix_ts_ms big-endian.
        bytes[0] = UInt8((ms >> 40) & 0xff)
        bytes[1] = UInt8((ms >> 32) & 0xff)
        bytes[2] = UInt8((ms >> 24) & 0xff)
        bytes[3] = UInt8((ms >> 16) & 0xff)
        bytes[4] = UInt8((ms >> 8) & 0xff)
        bytes[5] = UInt8(ms & 0xff)

        // Bits 48..59 = 12-bit monotonic counter.
        bytes[6] = UInt8((snapshotCounter >> 8) & 0x0f)
        bytes[7] = UInt8(snapshotCounter & 0xff)

        // Random bytes for the remaining `rand_b` section (bytes 8..15).
        // Use SecRandomCopyBytes for CSPRNG quality across Apple platforms.
        var random = [UInt8](repeating: 0, count: 8)
        _ = random.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buf.count, base)
        }
        for i in 0..<8 {
            bytes[8 + i] = random[i]
        }

        // Version = 7 — high nibble of byte 6.
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        // Variant = 10 (RFC 4122) — high two bits of byte 8.
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        return formatUuid(bytes)
    }

    /// **Internal** — testing seam to reset the monotonic counter so each
    /// test case starts from a known state. Not part of the public API.
    static func _resetForTests() {
        lock.lock()
        lastMs = 0
        counter = 0
        lock.unlock()
    }
}

private func formatUuid(_ bytes: [UInt8]) -> String {
    let hex = bytes.map { String(format: "%02x", $0) }
    return [
        hex[0..<4].joined(),
        hex[4..<6].joined(),
        hex[6..<8].joined(),
        hex[8..<10].joined(),
        hex[10..<16].joined()
    ].joined(separator: "-")
}
