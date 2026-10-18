import Foundation
import EcosystemLocalIPC

struct AthenaJob: Codable, Sendable {
    var rootID: UUID?
    var minimumSizeBytes: UInt64?
    var requesterRole: LocalRole?
    var requesterClientID: LocalMCPClient?
    var accessTicket: LocalAccessTicket?
}
struct AthenaSubmission: Codable, Sendable {
    let capability: String
    let job: AthenaJob
    let key: String
    var deadlineAt: String? = nil
}
struct AthenaRootTransfer: Codable, Sendable { let bookmark: Data }

/// GUI получает типизированные данные через тот же исполнитель, что и MCP.
/// Внешнему MCP не выдаются операции выбора/сканирования пользовательских папок.
public struct AthenaRemoteServices: SystemInformationProviding, SystemDiagnosing, StorageAnalyzing {
    public let client: Result<LocalRPCClient, Error>
    public init(client: Result<LocalRPCClient, Error>) { self.client = client }
    private func perform<T: Decodable & Sendable>(_ capability: String, job: AthenaJob = AthenaJob()) async throws -> T {
        let remote = try client.get()
        let task: LocalTaskID = try await remote.call("work.submit", AthenaSubmission(capability: capability, job: job, key: UUID().uuidString))
        return try await remote.waitForResult(task.id)
    }
    public func systemInfo() async throws -> SystemInfo { try await perform("system.get_info") }
    public func systemMetrics() async throws -> SystemMetrics { try await perform("system.get_metrics") }
    public func runDiagnostics() async throws -> DiagnosticReport { try await perform("diagnostics.run") }
    public func storageOverview() async throws -> StorageOverview { try await perform("storage.get_overview") }
    public func scanDirectory(at url: URL, minimumSizeBytes: UInt64) async throws -> [StorageItem] {
        let remote = try client.get()
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root: LocalTaskID = try await remote.call("grant.add", AthenaRootTransfer(bookmark: bookmark))
        return try await perform("storage.scan", job: AthenaJob(rootID: root.id, minimumSizeBytes: minimumSizeBytes))
    }
}
