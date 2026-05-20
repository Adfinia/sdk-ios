// Shared test helpers — fake transport, payload factory, debug logger.

import Foundation
@testable import AdfiniaSDK

/// Captures every batch passed to it and returns a configurable result.
final class CapturingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[AdfiniaPayload]] = []
    private var nextResult: TransportResult = .okEmpty
    private var resultQueue: [TransportResult] = []
    private var sendDelay: TimeInterval = 0

    func setNextResult(_ result: TransportResult) {
        lock.lock(); defer { lock.unlock() }
        nextResult = result
    }

    func setSendDelay(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        sendDelay = seconds
    }

    func queueResults(_ results: [TransportResult]) {
        lock.lock(); defer { lock.unlock() }
        resultQueue.append(contentsOf: results)
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return batches.count
    }

    var sentEvents: [AdfiniaPayload] {
        lock.lock(); defer { lock.unlock() }
        return batches.flatMap { $0 }
    }

    var lastBatch: [AdfiniaPayload]? {
        lock.lock(); defer { lock.unlock() }
        return batches.last
    }

    func send(_ batch: [AdfiniaPayload]) async -> TransportResult {
        lock.lock()
        batches.append(batch)
        let delay = sendDelay
        let result: TransportResult
        if !resultQueue.isEmpty {
            result = resultQueue.removeFirst()
        } else {
            result = nextResult
        }
        lock.unlock()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return result
    }
}

/// Builds a small AdfiniaPayload with a deterministic shape for queue tests.
func makePayload(event: String, type: AdfiniaPayloadType = .track) -> AdfiniaPayload {
    AdfiniaPayload(
        type: type,
        event: event,
        customerId: nil,
        anonymousId: "anon",
        previousId: nil,
        properties: nil,
        traits: nil,
        context: AdfiniaContext(
            library: AdfiniaLibraryInfo(name: "adfinia-sdk-ios", version: "test")
        ),
        sentAt: ISO8601DateFormatter.adfinia.string(from: Date()),
        messageId: "msg-\(event)"
    )
}

struct SilentLogger: EventQueueDebugLogger {
    func log(_ message: String) {}
}

/// Waits up to `timeout` for `condition` to return true. Polls every
/// 50 ms — coarser than vitest's fake-timer scheme but good enough for
/// the queue's 5s default flush interval (which tests override down to
/// fractions of a second).
func waitUntil(
    timeout: TimeInterval = 3,
    pollMs: UInt32 = 50,
    file: StaticString = #file,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
    }
    return condition()
}
