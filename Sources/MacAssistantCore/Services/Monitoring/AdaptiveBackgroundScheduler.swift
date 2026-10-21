import Foundation

/// Один event-driven цикл: без работы ждёт continuation без таймера. Сигнал
/// отменяет только ожидание, а не уже принятое действие/побочный эффект.
public actor AdaptiveBackgroundScheduler {
    private let tick: @Sendable () async -> Void
    private let delay: @Sendable () async -> TimeInterval?
    private var loop: Task<Void, Never>?
    private var timer: Task<Void, Error>?
    private var idle: CheckedContinuation<Void, Never>?
    private var generation: UInt64 = 0
    private var stopped = false
    public init(tick: @escaping @Sendable () async -> Void, delay: @escaping @Sendable () async -> TimeInterval?) {
        self.tick = tick; self.delay = delay
    }
    public func start() {
        guard loop == nil, !stopped else { return }
        loop = Task(priority: .background) { await self.run() }
    }
    public func wake() {
        generation &+= 1
        timer?.cancel(); idle?.resume(); idle = nil
    }
    public func stop() {
        stopped = true; wake()
    }
    private func run() async {
        while !stopped {
            let seen = generation
            await tick()
            let seconds = await delay()
            guard !stopped else { break }
            // Сигнал во время await не должен теряться перед установкой ожидания.
            if seen != generation { continue }
            if let seconds {
                let bounded = seconds.isFinite ? min(86_400, max(0.01, seconds)) : 60
                timer = Task { try await Task.sleep(for: .seconds(bounded), tolerance: .milliseconds(250)) }
                do { try await timer?.value } catch { /* wake отменяет только sleep */ }
                timer = nil
            } else {
                await withCheckedContinuation { idle = $0 }
            }
        }
        loop = nil
    }
}
