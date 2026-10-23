import Foundation

public enum ApplicationLocation: String, Codable, Sendable { case system, shared, user }
public enum ApplicationRootState: String, Codable, Sendable { case readable, missing, inaccessible, symbolicLink }
public struct ApplicationRootCoverage: Codable, Equatable, Sendable {
    public let location: ApplicationLocation
    public let state: ApplicationRootState
    public init(location: ApplicationLocation, state: ApplicationRootState) { self.location = location; self.state = state }
}

/// Размер относится к файлам bundle, не к Documents/кэшу приложения в Library.
/// allocated — оценка блоков файлов: APFS clones/compression не дают из неё
/// точное число байтов, которое освободится после удаления приложения.
public struct InstalledApplicationMetrics: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let location: ApplicationLocation
    public let logicalBytes: MonitoringMetric<UInt64>
    public let allocatedBytes: MonitoringMetric<UInt64>
    public let complete: Bool
    public let inaccessibleEntries: Int
    public let skippedSymbolicLinks: Int
    public init(id: String, name: String, location: ApplicationLocation,
                logicalBytes: MonitoringMetric<UInt64>, allocatedBytes: MonitoringMetric<UInt64>,
                complete: Bool, inaccessibleEntries: Int = 0, skippedSymbolicLinks: Int = 0) {
        self.id = id; self.name = name; self.location = location; self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes; self.complete = complete
        self.inaccessibleEntries = inaccessibleEntries; self.skippedSymbolicLinks = skippedSymbolicLinks
    }
}
public struct ApplicationInventoryMetrics: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let applications: [InstalledApplicationMetrics]
    public let roots: [ApplicationRootCoverage]
    public let discoveredApplications: Int
    public let visitedEntries: Int
    public let enumerationComplete: Bool
    public let limitReached: Bool
    public init(capturedAt: Date, applications: [InstalledApplicationMetrics], roots: [ApplicationRootCoverage],
                discoveredApplications: Int, visitedEntries: Int, enumerationComplete: Bool, limitReached: Bool) {
        self.capturedAt = capturedAt; self.applications = applications; self.roots = roots
        self.discoveredApplications = discoveredApplications; self.visitedEntries = visitedEntries
        self.enumerationComplete = enumerationComplete; self.limitReached = limitReached
    }
    var valid: Bool {
        applications.count <= 256 && roots.count <= 16 && (applications.count...1_000_000).contains(discoveredApplications) &&
        (0...1_000_000).contains(visitedEntries) && Set(applications.map(\.id)).count == applications.count &&
        applications.allSatisfy { row in
            !row.id.isEmpty && row.id.utf8.count <= 64 && row.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            row.name.utf8.count <= 256 && (0...1_000_000).contains(row.inaccessibleEntries) &&
            (0...1_000_000).contains(row.skippedSymbolicLinks)
        }
    }
}
