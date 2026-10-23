import Foundation
import EcosystemLocalIPC

/// ContinuousClock учитывает сон и не зависит от перевода настенных часов.
/// Инъекция одной пары часов позволяет проверять TTL/wake без реального ожидания.
public struct MonitoringInstant: Sendable {
    public let monotonic: TimeInterval
    public let date: Date
    public init(monotonic: TimeInterval, date: Date) { self.monotonic = monotonic; self.date = date }
}

public struct MonitoringClock: Sendable {
    public let now: @Sendable () -> MonitoringInstant
    public init(now: @escaping @Sendable () -> MonitoringInstant) { self.now = now }
    public static var live: Self {
        let origin = ContinuousClock.now
        return Self {
            let delta = origin.duration(to: .now).components
            return MonitoringInstant(monotonic: Double(delta.seconds) + Double(delta.attoseconds) / 1e18, date: .now)
        }
    }
}

public struct MonitoringCollection: Sendable {
    public let state: MeasurementState
    public let payload: MonitoringPayload?
    /// Локальная подсказка scheduler, не поле RPC. Cached collector сообщает
    /// оставшийся TTL, чтобы новая lease не продлевала старые данные на interval.
    public let refreshAfter: TimeInterval?
    public init(state: MeasurementState = .available, payload: MonitoringPayload? = nil, refreshAfter: TimeInterval? = nil) {
        self.state = state; self.payload = payload; self.refreshAfter = refreshAfter
    }
}

/// Каждый collector владеет своими baseline. Reset обязателен после wake,
/// потери всех подписок и отмены; чужой GUI/MCP sampler не меняет его историю.
public protocol MonitoringCollecting: Sendable {
    var group: MonitoringGroup { get }
    func collect(reset: Bool) async throws -> MonitoringCollection
}

/// O(1) вставка и удаление; графики не сдвигают массив при каждой секунде.
struct MonitoringRing<Element> {
    private var slots: [Element?]
    private var start = 0
    private(set) var count = 0
    init(capacity: Int) { slots = Array(repeating: nil, count: max(1, capacity)) }
    var first: Element? { count == 0 ? nil : slots[start] }
    mutating func append(_ item: Element) {
        if count == slots.count {
            slots[start] = item; start = (start + 1) % slots.count
        } else {
            slots[(start + count) % slots.count] = item; count += 1
        }
    }
    mutating func removeFirst() {
        guard count > 0 else { return }
        slots[start] = nil; start = (start + 1) % slots.count; count -= 1
    }
    var elements: [Element] { (0..<count).compactMap { slots[(start + $0) % slots.count] } }
}

/// Единственный владелец краткой RAM-истории и lease окон. Никаких disk writes,
/// глобального опроса без подписок или durable tasks на пути чтения снимков.
public actor MonitoringCoordinator: LiveMonitoringProviding {
    public static let leaseSeconds: TimeInterval = 15
    public static let maximumLeases = 16
    private struct Subscription { let groups: Set<MonitoringGroup>; var deadline: TimeInterval }
    private struct StoredSample { let at: MonitoringInstant; let sample: MonitoringSample }
    private struct StoredPoint { let monotonic: TimeInterval; let point: MonitoringHistoryPoint }
    private struct Job { let id: UUID; let epoch: UInt64; let task: Task<Void, Never> }

    private let clock: MonitoringClock
    private let automaticSampling: Bool
    private let collectors: [MonitoringGroup: any MonitoringCollecting]
    private var leases: [UUID: Subscription] = [:]
    private var active: Set<MonitoringGroup> = []
    private var latest: [MonitoringGroup: StoredSample] = [:]
    private var histories: [MonitoringGroup: MonitoringRing<StoredPoint>] = [:]
    private var jobs: [MonitoringGroup: Job] = [:]
    private var epochs: [MonitoringGroup: UInt64] = [:]
    private var needsReset: Set<MonitoringGroup> = []
    private var invalidSamples: Set<MonitoringGroup> = []
    private var nextDue: [MonitoringGroup: TimeInterval] = [:]
    private var lastCollected: [MonitoringGroup: TimeInterval] = [:]
    private var lastPulse: TimeInterval?
    private var loop: Task<Void, Never>?
    private var loopGeneration: UInt64 = 0
    private var suspended = false
    private var closed = false
    private var emergencyRevision: UInt64 = 0

    public init(collectors: [any MonitoringCollecting], clock: MonitoringClock = .live, automaticSampling: Bool = true) {
        // Повторный канал не создаёт второй цикл; первая реализация имеет приоритет.
        self.collectors = Dictionary(collectors.map { ($0.group, $0) }, uniquingKeysWith: { first, _ in first })
        self.clock = clock; self.automaticSampling = automaticSampling
    }

    deinit { loop?.cancel(); for job in jobs.values { job.task.cancel() } }

    public func subscribe(groups: Set<MonitoringGroup>) throws -> MonitoringLease {
        try Task.checkCancellation()
        let now = clock.now(); reconcile(now)
        guard !suspended, !closed else { throw LocalRuntimeFailure.busy }
        guard !groups.isEmpty else { throw LocalRuntimeFailure.invalidRequest }
        guard leases.count < Self.maximumLeases else { throw LocalRuntimeFailure.busy }
        let id = UUID()
        leases[id] = Subscription(groups: groups, deadline: now.monotonic + Self.leaseSeconds)
        reconcile(now); poll(); startLoop()
        return MonitoringLease(id: id, expiresAt: now.date.addingTimeInterval(Self.leaseSeconds))
    }

    public func renew(_ id: UUID) throws -> MonitoringLease {
        try Task.checkCancellation()
        let now = clock.now(); reconcile(now)
        guard !suspended, !closed, var lease = leases[id] else { throw LocalRuntimeFailure.denied }
        lease.deadline = now.monotonic + Self.leaseSeconds; leases[id] = lease
        return MonitoringLease(id: id, expiresAt: now.date.addingTimeInterval(Self.leaseSeconds))
    }

    /// Идемпотентное закрытие допускается даже из уже отменённой View.task.
    public func unsubscribe(_ id: UUID) {
        leases.removeValue(forKey: id); reconcile(clock.now())
    }

    public func snapshot() -> MonitoringSnapshot {
        let now = clock.now(); reconcile(now)
        let samples = MonitoringGroup.allCases.map { group -> MonitoringSample in
            guard let stored = latest[group] else {
                return MonitoringSample(group: group, capturedAt: now.date, intervalSeconds: nil,
                    state: active.contains(group) && collectors[group] != nil ? .warmingUp : .unavailable,
                    payload: nil, stale: true)
            }
            let age = now.monotonic - stored.at.monotonic
            return MonitoringSample(group: group, capturedAt: stored.sample.capturedAt,
                intervalSeconds: stored.sample.intervalSeconds, state: stored.sample.state,
                payload: stored.sample.payload,
                stale: suspended || invalidSamples.contains(group) || !active.contains(group) || age < 0 || age > max(3, group.interval * 2))
        }
        return MonitoringSnapshot(suspended: suspended, samples: samples)
    }

    public func history(_ query: MonitoringHistoryQuery) throws -> [MonitoringHistoryPoint] {
        guard query.valid else { throw LocalRuntimeFailure.invalidRequest }
        let now = clock.now(); reconcile(now)
        let rows = histories[query.group]?.elements.filter {
            $0.monotonic >= now.monotonic - Double(query.windowSeconds) && $0.monotonic <= now.monotonic
        }.map(\.point) ?? []
        guard rows.count > query.maximumPoints else { return rows }
        // Крайние точки сохраняются. В каждом внутреннем бакете разрыв имеет
        // приоритет: downsampling не должен спрятать wake/error и нарисовать
        // непрерывную линию там, где измерений не было. Это не среднее значение.
        let middle = query.maximumPoints - 2
        var selected = [rows[0]]
        if middle > 0 {
            for index in 0..<middle {
                let start = 1 + index * (rows.count - 2) / middle
                let end = 1 + (index + 1) * (rows.count - 2) / middle
                let bucket = rows[start..<end]
                selected.append(bucket.last { $0.state != .available || $0.values.isEmpty } ?? rows[end - 1])
            }
        }
        selected.append(rows[rows.count - 1])
        return selected
    }

    /// Обновление разрешено только активному GUI subscriber. Сначала отменяем
    /// прежний обход и ограждаем его epoch; занятый slot не переиспользуется,
    /// пока callback действительно не завершился. Stop во время await не снимаем.
    public func refreshApplications() async throws {
        reconcile(clock.now())
        guard !suspended, !closed, active.contains(.applications),
              let collector = collectors[.applications] as? any MonitoringCacheInvalidating else { throw LocalRuntimeFailure.busy }
        invalidate(.applications)
        await collector.invalidateCache()
        guard !suspended, !closed, active.contains(.applications) else { throw LocalRuntimeFailure.busy }
        nextDue[.applications] = clock.now().monotonic
        poll()
    }

    /// Ревизия задаётся runtime до await durable latch. Запоздавший запрос
    /// status не может снова остановить сбор после более нового GUI resume.
    func synchronizeEmergency(suspended: Bool, revision: UInt64) {
        guard revision >= emergencyRevision else { return }
        emergencyRevision = revision
        if suspended { suspend() } else { resume() }
    }

    public func suspend() {
        suspended = true; leases.removeAll(); reconcile(clock.now())
    }

    /// Возобновление снимает запрет; старые lease не оживают без подписки GUI.
    public func resume() { if !closed { suspended = false } }
    public func shutdown() { closed = true; suspend() }

    /// Явный системный wake и большие разрывы часов инвалидируют baseline и
    /// запоздавшие ответы. Некооперативный collector сохраняет занятый слот
    /// до завершения, поэтому повторная подписка не создаёт второй вызов.
    public func invalidateBaselines() {
        let now = clock.now(); reconcile(now)
        for group in active { invalidate(group); nextDue[group] = now.monotonic; appendGap(group, now: now) }
        lastPulse = now.monotonic
    }

    /// В production вызывается одним секундным loop; тесты управляют clock/poll.
    func poll() {
        let now = clock.now(); reconcile(now)
        guard !suspended, !closed, !active.isEmpty else { return }
        if let previous = lastPulse, now.monotonic < previous || now.monotonic - previous > 5 {
            for group in active { invalidate(group); nextDue[group] = now.monotonic; appendGap(group, now: now) }
        }
        lastPulse = now.monotonic
        for group in active {
            guard let collector = collectors[group], jobs[group] == nil,
                  now.monotonic >= (nextDue[group] ?? now.monotonic) else { continue }
            // Во время долгого обновления показываем старый каталог как stale,
            // а не как только что завершённый scan. Короткий RAM cache очищает
            // этот флаг в complete так же, как результат настоящего обхода.
            if group == .applications, latest[group] != nil { invalidSamples.insert(group) }
            let reset = needsReset.remove(group) != nil
            let epoch = epochs[group, default: 0], id = UUID()
            let previous = reset ? nil : lastCollected[group]
            nextDue[group] = now.monotonic + group.interval
            // Detached защищает actor координации даже от синхронного участка
            // файлового collector до его первого await. Публикация fenced по epoch.
            let task = Task.detached(priority: .utility) { [weak self] in
                let result: MonitoringCollection
                do { result = try await collector.collect(reset: reset) }
                catch { result = MonitoringCollection(state: .unavailable) }
                await self?.complete(group, id: id, epoch: epoch, at: now, previous: previous,
                                     result: result, cancelled: Task.isCancelled)
            }
            jobs[group] = Job(id: id, epoch: epoch, task: task)
        }
    }

    /// Test seam ожидает реальное завершение принятых выборок без polling sleeps.
    func waitForCollections() async {
        let current = jobs.values.map(\.task)
        for task in current { await task.value }
    }

    private func complete(_ group: MonitoringGroup, id: UUID, epoch: UInt64, at: MonitoringInstant,
                          previous: TimeInterval?, result: MonitoringCollection, cancelled: Bool) {
        guard jobs[group]?.id == id else { return }
        jobs.removeValue(forKey: group)
        let now = clock.now(); reconcile(now)
        guard !cancelled, !suspended, !closed, active.contains(group), epochs[group, default: 0] == epoch else { return }
        // Ответ за пределами допустимого окна не должен стать «свежим» после
        // долгой блокировки API; следующий вызов снова получает reset.
        guard now.monotonic >= at.monotonic, now.monotonic - at.monotonic <= max(3, group.interval * 2) else {
            invalidate(group); nextDue[group] = now.monotonic; appendGap(group, now: now); return
        }
        let payloadValid = result.payload.map { $0.group == group && $0.validated() } ?? (result.state != .available)
        let state = payloadValid ? result.state : .unavailable
        let payload = payloadValid ? result.payload : nil
        let interval = previous.map { at.monotonic - $0 }.flatMap { $0 > 0 ? $0 : nil }
        latest[group] = StoredSample(at: at, sample: MonitoringSample(group: group, capturedAt: at.date,
            intervalSeconds: interval, state: state, payload: payload, stale: false))
        invalidSamples.remove(group)
        if payloadValid, state != .unavailable, let delay = result.refreshAfter, delay.isFinite, delay > 0 {
            // Подсказка может только приблизить следующий опрос, но не отложить
            // штатный interval. Нижняя граница исключает tight loop на epsilon TTL.
            let due = now.monotonic + max(0.1, min(group.interval, delay))
            nextDue[group] = min(nextDue[group] ?? due, due)
        }
        if state == .unavailable { needsReset.insert(group) }
        lastCollected[group] = at.monotonic
        appendHistory(group, at: at, state: state, values: payload?.graphValues ?? [:])
    }

    private func invalidate(_ group: MonitoringGroup) {
        epochs[group, default: 0] &+= 1; needsReset.insert(group); invalidSamples.insert(group)
        lastCollected.removeValue(forKey: group); jobs[group]?.task.cancel()
    }

    private func reconcile(_ now: MonitoringInstant) {
        leases = leases.filter { $0.value.deadline > now.monotonic }
        let selected = suspended || closed ? Set<MonitoringGroup>() : leases.values.reduce(into: Set<MonitoringGroup>()) { $0.formUnion($1.groups) }
        for group in active.subtracting(selected) { invalidate(group); nextDue.removeValue(forKey: group) }
        for group in selected.subtracting(active) {
            invalidate(group); nextDue[group] = now.monotonic
            if latest[group] != nil { appendGap(group, now: now) }
        }
        active = selected
        for group in Array(histories.keys) {
            while let point = histories[group]?.first,
                  point.monotonic < now.monotonic - 900 || point.monotonic > now.monotonic {
                histories[group]?.removeFirst()
            }
        }
        if active.isEmpty {
            lastPulse = nil; loop?.cancel(); loop = nil; loopGeneration &+= 1
        }
    }

    private func appendGap(_ group: MonitoringGroup, now: MonitoringInstant) {
        latest[group] = StoredSample(at: now, sample: MonitoringSample(group: group, capturedAt: now.date,
            intervalSeconds: nil, state: .warmingUp, payload: nil, stale: false))
        appendHistory(group, at: now, state: .warmingUp, values: [:])
    }

    private func appendHistory(_ group: MonitoringGroup, at: MonitoringInstant, state: MeasurementState, values: [String: Double]) {
        guard group != .processes, group != .applications else { return }
        if histories[group] == nil { histories[group] = MonitoringRing(capacity: 900) }
        histories[group]?.append(StoredPoint(monotonic: at.monotonic,
            point: MonitoringHistoryPoint(capturedAt: at.date, state: state, values: values)))
    }

    private func startLoop() {
        guard automaticSampling, loop == nil, !active.isEmpty, !suspended, !closed else { return }
        loopGeneration &+= 1; let generation = loopGeneration
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(50)) }
                catch { break }
                guard let self, await self.pulse() else { break }
            }
            await self?.loopFinished(generation)
        }
    }
    private func pulse() -> Bool { poll(); return !active.isEmpty && !closed && !suspended }
    private func loopFinished(_ generation: UInt64) { if generation == loopGeneration { loop = nil } }
}
