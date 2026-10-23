import Foundation
import EcosystemLocalization
import MacAssistantCore

/// Суммируем только footprint подтверждённого bundle. Неизвестные процессы
/// остаются отдельными строками; частичная сумма помечается, nil не равен нулю.
struct MemoryDisplayRow: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64?
    let members: Int
    let unavailable: Int
    let partial: Bool
    let pid: Int32?

    static func make(_ processes: [ProcessMemoryMetrics], applications: Bool,
                     search: String, sortByName: Bool, coverageIncomplete: Bool = false) -> [MemoryDisplayRow] {
        let groups = Dictionary(grouping: processes) { row in
            applications ? row.applicationID.map { "app." + $0 } ?? "pid.\(row.pid)" : "pid.\(row.pid)"
        }
        let rows = groups.map { id, members -> MemoryDisplayRow in
            let first = members[0]
            var total: UInt64 = 0, known = 0, overflow = false
            for member in members {
                if let value = member.footprintBytes.value {
                    let sum = total.addingReportingOverflow(value)
                    overflow = overflow || sum.overflow; total = sum.partialValue; known += 1
                }
            }
            return MemoryDisplayRow(id: id, name: applications ? first.applicationName ?? first.name : first.name,
                bytes: known > 0 && !overflow ? total : nil, members: members.count,
                unavailable: members.count - known,
                partial: known < members.count || (id.hasPrefix("app.") && coverageIncomplete), pid: id.hasPrefix("pid.") ? first.pid : nil)
        }.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.pid.map(String.init)?.contains(search) == true }
        return rows.sorted {
            if sortByName {
                let result = $0.name.localizedStandardCompare($1.name)
                if result != .orderedSame { return result == .orderedAscending }
            } else if $0.bytes != $1.bytes {
                // Даже измеренный ноль располагается выше отсутствующего измерения.
                if $0.bytes == nil { return false }; if $1.bytes == nil { return true }
                return ($0.bytes ?? 0) > ($1.bytes ?? 0)
            }
            return $0.id < $1.id
        }
    }
}

struct MemoryChartPoint: Identifiable {
    let id: String
    let date: Date
    let bytes: Double
    let key: String
    let segment: String
    static func make(_ history: [MonitoringHistoryPoint]) -> [MemoryChartPoint] {
        var output: [MemoryChartPoint] = []
        for key in ["used", "compressed", "swapUsed"] {
            var segment = 0
            var previous: Date?
            for (index, row) in history.enumerated() {
                guard row.state == .available, let value = row.values[key], value.isFinite, value >= 0 else {
                    segment += 1; previous = nil; continue
                }
                if let previous, row.capturedAt <= previous { segment += 1 }
                previous = row.capturedAt
                output.append(MemoryChartPoint(id: "\(key).\(index)", date: row.capturedAt, bytes: value,
                                               key: key, segment: "\(key).\(segment)"))
            }
        }
        return output
    }
}

enum MemoryFormat {
    /// Int64 conversion ограничен: UInt64.max в недоверенном payload не должен
    /// обрушать GUI. Единицы соответствуют выбранному языку интерфейса;
    /// memory style использует степени 1024, как показатели macOS.
    static func bytes(_ value: UInt64?, language: AgentLanguage = .english) -> String {
        guard let value, value <= UInt64(Int64.max) else { return "—" }
        return ByteCountFormatStyle(style: .memory, spellsOutZero: false,
                                   locale: Locale(identifier: language.rawValue)).format(Int64(value))
    }
}
