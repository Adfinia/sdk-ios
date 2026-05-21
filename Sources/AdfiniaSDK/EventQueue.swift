// Persistent event queue with exponential-backoff retries.
//
// Mirrors `sdks/web/src/queue.ts`. Behaviour:
//   - flushAt events or flushIntervalSeconds → flush
//   - 4xx → drop (with debug log)
//   - 5xx + network → retry with exponential backoff (1s → 30s cap)
//   - maxQueueSize cap → drop oldest first
//   - buffer is persisted to the KV store on every mutation so a crash
//     between flushes still replays on next launch

import Foundation

protocol EventQueueDebugLogger: Sendable {
    func log(_ message: String)
}

struct PrintDebugLogger: EventQueueDebugLogger {
    let enabled: Bool
    func log(_ message: String) {
        guard enabled else { return }
        print("[adfinia] \(message)")
    }
}

struct EventQueueConfig {
    let store: AdfiniaKVStore
    let transport: Transport
    let flushAt: Int
    let flushIntervalSeconds: TimeInterval
    let maxQueueSize: Int
    let logger: EventQueueDebugLogger
    /// Callback fired when an identify call returns a server-resolved
    /// customer_id. Lets the client cache it back into IdentityStore.
    let onResolvedCustomerId: ((String) -> Void)?
}

final class EventQueue: @unchecked Sendable {
    static let storageKey = "adfinia.queue"

    private let cfg: EventQueueConfig
    /// Serial queue isolating all queue mutations + flushes.
    private let workQueue = DispatchQueue(label: "com.adfinia.sdk.queue")
    private var buffer: [AdfiniaPayload] = []
    private var inflight = false
    private var retryDelaySeconds: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var destroyed = false

    /// Effective knobs — start at the cfg defaults and may be tightened by
    /// applyRemoteConfig() after a successful GET /api/v1/sdk/config.
    private var effectiveFlushAt: Int
    private var effectiveFlushInterval: TimeInterval

    init(config: EventQueueConfig) {
        self.cfg = config
        self.effectiveFlushAt = config.flushAt
        self.effectiveFlushInterval = config.flushIntervalSeconds
        self.buffer = Self.load(from: config.store)
        // Defer scheduling until after init() so the timer doesn't fire
        // before the caller has wired up `onResolvedCustomerId`, etc.
        workQueue.async { [weak self] in self?.scheduleNextLocked() }
    }

    /// Apply config knobs received from GET /api/v1/sdk/config. Soft —
    /// nil fields keep the existing value. Reschedules the next flush so
    /// a tighter interval takes effect right away.
    func applyRemoteConfig(flushAt: Int?, flushIntervalSeconds: TimeInterval?) {
        workQueue.async { [weak self] in
            guard let self = self, !self.destroyed else { return }
            var changed = false
            if let f = flushAt, f > 0, f != self.effectiveFlushAt {
                self.effectiveFlushAt = f
                changed = true
            }
            if let i = flushIntervalSeconds, i > 0, i != self.effectiveFlushInterval {
                self.effectiveFlushInterval = i
                changed = true
            }
            if changed { self.scheduleNextLocked() }
        }
    }

    private static func load(from store: AdfiniaKVStore) -> [AdfiniaPayload] {
        guard let raw = store.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([AdfiniaPayload].self, from: data)
        else { return [] }
        return parsed
    }

    private func persistLocked() {
        if buffer.isEmpty {
            cfg.store.remove(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(buffer),
              let json = String(data: data, encoding: .utf8)
        else { return }
        cfg.store.set(json, forKey: Self.storageKey)
    }

    func enqueue(_ payload: AdfiniaPayload) {
        workQueue.async { [weak self] in
            guard let self = self, !self.destroyed else { return }
            self.buffer.append(payload)
            if self.buffer.count > self.cfg.maxQueueSize {
                let dropped = self.buffer.count - self.cfg.maxQueueSize
                self.buffer.removeFirst(dropped)
                self.cfg.logger.log("queue overflow — dropped \(dropped) oldest event(s)")
            }
            self.persistLocked()
            if self.buffer.count >= self.effectiveFlushAt {
                self.flushLocked()
            }
        }
    }

    /// Public flush — awaits completion of the in-flight batch (if any)
    /// and any newly-triggered send.
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workQueue.async { [weak self] in
                guard let self = self else { cont.resume(); return }
                self.flushLocked(completion: { cont.resume() })
            }
        }
    }

    /// Drain everything in the buffer and return it without sending.
    /// Used by `reset()`-style operations + the test surface.
    func drainAll() -> [AdfiniaPayload] {
        workQueue.sync {
            let drained = buffer
            buffer.removeAll()
            persistLocked()
            return drained
        }
    }

    var count: Int {
        workQueue.sync { buffer.count }
    }

    func destroy() {
        workQueue.sync {
            destroyed = true
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Internal (workQueue-isolated)

    private func flushLocked(completion: (() -> Void)? = nil) {
        guard !destroyed else { completion?(); return }
        guard !inflight else { completion?(); return }
        guard !buffer.isEmpty else { completion?(); return }

        inflight = true
        let sending = Array(buffer.prefix(effectiveFlushAt))
        let sendingCount = sending.count
        let transport = cfg.transport
        let logger = cfg.logger
        let onResolved = cfg.onResolvedCustomerId

        Task { [weak self] in
            let result = await transport.send(sending)
            guard let self = self else { completion?(); return }
            self.workQueue.async {
                if result.ok {
                    if sendingCount <= self.buffer.count {
                        self.buffer.removeFirst(sendingCount)
                    } else {
                        self.buffer.removeAll()
                    }
                    self.persistLocked()
                    self.retryDelaySeconds = 0
                    logger.log("flushed \(sendingCount) event(s)")
                    if let id = result.resolvedCustomerId { onResolved?(id) }
                } else if result.permanent {
                    if sendingCount <= self.buffer.count {
                        self.buffer.removeFirst(sendingCount)
                    } else {
                        self.buffer.removeAll()
                    }
                    self.persistLocked()
                    logger.log(
                        "dropped \(sendingCount) event(s) on permanent failure status=\(result.status.map(String.init) ?? "n/a")"
                    )
                } else {
                    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s cap.
                    self.retryDelaySeconds = self.retryDelaySeconds == 0
                        ? 1.0
                        : min(self.retryDelaySeconds * 2, 30.0)
                    logger.log(
                        "retrying in \(self.retryDelaySeconds)s (status=\(result.status.map(String.init) ?? "network"))"
                    )
                }
                self.inflight = false
                self.scheduleNextLocked()
                completion?()
            }
        }
    }

    private func scheduleNextLocked() {
        if destroyed { return }
        timer?.cancel()
        let delay = retryDelaySeconds > 0 ? retryDelaySeconds : effectiveFlushInterval
        let t = DispatchSource.makeTimerSource(queue: workQueue)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        t.resume()
        timer = t
    }
}
