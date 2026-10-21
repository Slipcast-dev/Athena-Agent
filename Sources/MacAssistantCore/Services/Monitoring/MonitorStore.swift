import Darwin
import Foundation
import EcosystemLocalIPC

/// Единственный writer живёт под lease AthenaRuntime. Atomic rename + fsync
/// фиксируют конфигурации, окна и события вместе; частичный файл не принимается.
public actor MonitorStore {
    private struct Document: Codable { var version = 1; var entries: [MonitorEntry] = []; var plans: [MonitorPlan] = []; var history: [MonitorEvent] = [] }
    private let file: URL
    private var document: Document
    private var wake: (@Sendable () -> Void)?
    /// Сигнал вызывается после durable commit; никакого опроса документа извне.
    public func setBackgroundWake(_ action: @escaping @Sendable () -> Void) { wake = action }
    /// Минимум5s применяется лишь к уже просроченному замеру/занятой очереди.
    /// Обычный интервал считается от фактического lastSampleAt, без дрейфа tick.
    public func nextBackgroundDelay(now: Date = Date()) -> TimeInterval? {
        let deadlines = document.entries.filter { $0.enabled && $0.approvedRevision == $0.rule.fingerprint }.map { entry in
            entry.state.lastSampleAt.map { now < $0 ? now : $0.addingTimeInterval(Double(entry.rule.intervalSeconds)) } ?? now
        }
        return deadlines.min().map { max(5, $0.timeIntervalSince(now)) }
    }
    public init(directory: URL) throws {
        file = directory.appendingPathComponent("monitors-v1.json")
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, info.st_size <= 8_388_608 else { throw LocalRuntimeFailure.invalidConfiguration }
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1, document.entries.count <= 32, document.history.count <= 1000, document.plans.count <= 64,
                  Set(document.entries.map(\.id)).count == document.entries.count else { throw LocalRuntimeFailure.invalidConfiguration }
            for entry in document.entries { try entry.rule.validate(); guard !entry.enabled || entry.approvedRevision == entry.rule.fingerprint else { throw LocalRuntimeFailure.invalidConfiguration } }
        } else { document = Document() }
    }
    private func persist(_ next: Document) throws {
        let data = try JSONEncoder().encode(next)
        guard data.count <= 8_388_608 else { throw LocalRuntimeFailure.busy }
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalRuntimeFailure.operationFailed }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw LocalRuntimeFailure.operationFailed }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw LocalRuntimeFailure.operationFailed }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
        document = next; wake?()
    }
    public func entries() -> [MonitorEntry] { document.entries }
    public func entry(_ id: UUID) throws -> MonitorEntry {
        guard let entry = document.entries.first(where: { $0.id == id }) else { throw LocalRuntimeFailure.invalidRequest }; return entry
    }
    public func propose(_ input: MonitorRule) throws -> MonitorEntry {
        try input.validate(); guard document.entries.count < 32 else { throw LocalRuntimeFailure.busy }
        var rule = input; rule.id = UUID()
        let entry = MonitorEntry(rule: rule)
        var next = document; next.entries.append(entry); try persist(next); return entry
    }
    public func requestEnable(_ id: UUID, now: Date = Date(), accessTicket: LocalAccessTicket? = nil) throws -> MonitorPlan {
        let value = try entry(id)
        var plan = MonitorPlan(id: UUID(), monitorID: id, fingerprint: value.rule.fingerprint, expiresAt: now.addingTimeInterval(300))
        plan.accessTicket = accessTicket
        var next = document; next.plans.removeAll { $0.consumed || $0.expiresAt <= now || $0.monitorID == id }
        guard next.plans.count < 64 else { throw LocalRuntimeFailure.busy }
        next.plans.append(plan); try persist(next); return plan
    }
    public func pending(now: Date = Date()) -> [MonitorPlan] { document.plans.filter { !$0.consumed && $0.expiresAt > now } }
    public func approve(_ id: UUID, fingerprint: String, role: LocalRole, now: Date = Date()) throws -> MonitorEntry {
        guard role == .gui else { throw LocalRuntimeFailure.denied }
        guard let index = document.plans.firstIndex(where: { $0.id == id }), !document.plans[index].consumed,
              document.plans[index].expiresAt > now, document.plans[index].fingerprint == fingerprint,
              let item = document.entries.firstIndex(where: { $0.id == document.plans[index].monitorID }),
              document.entries[item].rule.fingerprint == fingerprint else { throw LocalRuntimeFailure.staleSnapshot }
        var next = document; next.entries[item].enabled = true; next.entries[item].approvedRevision = fingerprint
        next.entries[item].state = MonitorState(); next.plans[index].consumed = true
        try persist(next); return next.entries[item]
    }
    public func disable(_ id: UUID) throws -> MonitorEntry {
        guard let item = document.entries.firstIndex(where: { $0.id == id }) else { throw LocalRuntimeFailure.invalidRequest }
        var next = document; next.entries[item].enabled = false; next.entries[item].approvedRevision = nil
        for i in next.plans.indices where next.plans[i].monitorID == id { next.plans[i].consumed = true }
        try persist(next); return next.entries[item]
    }
    public func due(now: Date = Date()) -> [MonitorEntry] {
        document.entries.filter { entry in entry.enabled && entry.approvedRevision == entry.rule.fingerprint && (entry.state.lastSampleAt.map { now.timeIntervalSince($0) >= Double(entry.rule.intervalSeconds) || now < $0 } ?? true) }
    }
    public func record(id: UUID, revision: String, metrics: SystemMetrics?, now: Date) throws {
        // disable во время await измерения не позволяет сохранить запоздалый результат.
        guard let i = document.entries.firstIndex(where: { $0.id == id }), document.entries[i].enabled,
              document.entries[i].approvedRevision == revision, document.entries[i].rule.fingerprint == revision else { return }
        let entry = document.entries[i]
        let value = metrics.flatMap { MonitorEvaluator.value($0, metric: entry.rule.metric, now: now) }
        let warming = entry.rule.metric == .cpu && metrics?.quality(now: now).cpu == .warmingUp
        let (state, event) = MonitorEvaluator.step(rule: entry.rule, state: entry.state, value: value, now: now, warmingUp: warming)
        var next = document; next.entries[i].state = state
        if let event { next.history.append(event); next.history = Array(next.history.suffix(1000)) }
        try persist(next)
    }
    /// Runtime переносит весь ограниченный журнал, а не одну UI-страницу.
    /// Снимок берётся за один actor turn: append/retention во время последующих
    /// await не сдвигают offset и не выкидывают записи из уже взятой партии.
    /// Новые события попадут в следующую партию; durable inbox дедуплицирует ID.
    func historyForDelivery() -> [MonitorEvent] {
        Array(document.history.reversed())
    }
    public func history(_ id: UUID?, offset: Int) throws -> MonitorHistoryPage {
        guard (0...100_000).contains(offset) else { throw LocalRuntimeFailure.invalidRequest }
        if let id { _ = try entry(id) }
        let rows = document.history.reversed().filter { id == nil || $0.monitorID == id }
        let items = Array(rows.dropFirst(offset).prefix(100))
        return MonitorHistoryPage(items: items, nextOffset: offset + items.count < rows.count ? offset + items.count : nil)
    }
}
