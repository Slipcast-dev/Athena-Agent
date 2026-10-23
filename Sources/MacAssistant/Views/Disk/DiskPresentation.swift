import Foundation
import EcosystemLocalization
import MacAssistantCore

enum DiskApplicationSort: String, CaseIterable { case logical, allocated, name }
enum DiskApplicationPresentation {
    static func rows(_ rows: [InstalledApplicationMetrics], search: String, sort: DiskApplicationSort) -> [InstalledApplicationMetrics] {
        rows.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted { left, right in
            if sort == .name {
                let order = left.name.localizedStandardCompare(right.name)
                if order != .orderedSame { return order == .orderedAscending }
            } else {
                let a = sort == .logical ? left.logicalBytes.value : left.allocatedBytes.value
                let b = sort == .logical ? right.logicalBytes.value : right.allocatedBytes.value
                if a != b { if a == nil { return false }; if b == nil { return true }; return (a ?? 0) > (b ?? 0) }
            }
            return left.id < right.id
        }
    }
}
enum DiskFormat {
    static func bytes(_ value: UInt64?, language: AgentLanguage, complete: Bool = true) -> String {
        guard let value, value <= UInt64(Int64.max) else { return "—" }
        let formatted = ByteCountFormatStyle(style: .file, spellsOutZero: false,
            locale: Locale(identifier: language.rawValue)).format(Int64(value))
        return (complete ? "" : "≥ ") + formatted
    }
}
