import SwiftUI
import EcosystemLocalization
import MacAssistantCore

struct DiskView: View {
    @Environment(\.agentLanguage) private var language
    @StateObject private var model: DiskViewModel
    @State private var visible = false
    @State private var paused = false
    @State private var showingFolderAnalysis = false
    private let storage: any StorageAnalyzing
    init(container: AppContainer) { storage = container.services.storage; _model = StateObject(wrappedValue: DiskViewModel(provider: container.services.liveMonitoring)) }
    var body: some View {
        DiskContent(model: model, paused: paused || !visible)
            .navigationTitle(AthenaLocalization(language: language).text("Диск"))
            .sheet(isPresented: $showingFolderAnalysis) {
                FolderAnalysisView(storage: storage).frame(minWidth: 600, minHeight: 460)
            }
            .toolbar {
                Button(AthenaLocalization(language: language).text("Крупные файлы"), systemImage: "doc.text.magnifyingglass") { showingFolderAnalysis = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button(AthenaLocalization(language: language).text(paused ? "Продолжить мониторинг" : "Приостановить мониторинг"),
                       systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            .background(DashboardWindowVisibility { visible = $0 })
            .task(id: visible && !paused) {
                guard visible && !paused else { return }
                await model.runWhileVisible()
            }
    }
}
struct DiskContent: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: DiskViewModel
    var paused = false
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    private var dimmed: Bool { paused || model.suspended || model.runtimeError != nil || model.sample?.stale == true }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
                Picker(l10n.text("Том"), selection: $model.selectedVolume) {
                    if model.volumes.isEmpty { Text(l10n.text("Нет данных")).tag("") }
                    ForEach(model.volumes, id: \.id) { Text($0.name ?? $0.id).tag($0.id) }
                }.pickerStyle(.menu).frame(maxWidth: 400, alignment: .leading)
                if let path = model.metrics?.mountPath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    card(l10n.text("Ёмкость"), model.metrics?.totalBytes.value)
                    card(l10n.text("Занято на диске"), model.metrics?.usedBytes.value)
                    card(l10n.text("Свободно на диске"), model.metrics?.freeBytes.value)
                    card(l10n.text("Доступно для важных записей"), model.metrics?.availableForImportantUsageBytes.value)
                }.opacity(dimmed ? 0.6 : 1)
                if let total = model.metrics?.totalBytes.value, let used = model.metrics?.usedBytes.value, total > 0 {
                    ProgressView(l10n.text("Заполнение тома"), value: Double(used), total: Double(total)).opacity(dimmed ? 0.6 : 1)
                }
                if model.metrics?.readOnly == true { Label(l10n.text("Том доступен только для чтения"), systemImage: "lock").font(.caption) }
                Text(l10n.text("Показано до 32 локальных томов. Тома APFS могут использовать общий контейнер; их ёмкости не складываются."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l10n.text("Доступное для важных записей место учитывает ресурсы, которые macOS может освободить; оно отличается от свободного места."))
                    .font(.caption).foregroundStyle(.secondary)
                inventory
            }.padding(20)
        }
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.runtimeError { Text(l10n.render(.runtime(error))) }
            else if model.suspended { Text(l10n.text("Мониторинг остановлен аварийной кнопкой. Возобновите его в настройках.")) }
            else if paused { Text(l10n.text("Обновление приостановлено")) }
            else if model.sample?.stale == true { Text(l10n.text("Данные устарели. Ожидание свежего измерения.")) }
            else if let sample = model.sample, sample.state != .available { Text(AthenaMetricPresentation.stateTitle(sample.state, using: l10n)) }
            else { Text(l10n.text("Ёмкость томов обновляется каждые 10 секунд")) }
            if let date = model.sample?.capturedAt { Text(l10n.format("Обновлено: %@", date.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    private func card(_ title: String, _ value: UInt64?) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(DiskFormat.bytes(value, language: language)).font(.title2.weight(.semibold)).monospacedDigit()
        }.padding(4).frame(maxWidth: .infinity, alignment: .leading) }.accessibilityElement(children: .combine)
    }
    private var inventory: some View {
        GroupBox(l10n.text("Установленные приложения")) {
            VStack(alignment: .leading, spacing: 12) {
                inventoryStatus
                if let error = model.refreshError { Text(l10n.render(.runtime(error))) }
                ViewThatFits(in: .horizontal) {
                    HStack { sortPicker; Spacer(); refreshButton }
                    VStack(alignment: .leading) { sortPicker; refreshButton }
                }
                TextField(l10n.text("Поиск приложения"), text: $model.search).textFieldStyle(.roundedBorder)
                Table(model.applications) {
                    TableColumn(l10n.text("Приложение")) { row in
                        VStack(alignment: .leading) {
                            Text(row.name).lineLimit(1).help(row.name)
                            Text(location(row.location)).font(.caption).foregroundStyle(.secondary)
                            if !row.complete { Text(l10n.text("Размер определён частично")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn(l10n.text("Размер файлов")) { row in
                        Text(DiskFormat.bytes(row.logicalBytes.value, language: language, complete: row.complete)).monospacedDigit()
                    }.width(min: 100, ideal: 140)
                    TableColumn(l10n.text("На диске, оценка")) { row in
                        Text(DiskFormat.bytes(row.allocatedBytes.value, language: language, complete: row.complete)).monospacedDigit()
                    }.width(min: 100, ideal: 140)
                }.frame(height: 320)
                    .opacity(paused || model.suspended || model.applicationSample?.stale == true ? 0.6 : 1)
                    .overlay { if model.applications.isEmpty { Text(l10n.text("Нет приложений для отображения")) } }
                Text(l10n.text("Размеры относятся к файлам приложения, включая вложенные компоненты. Данные и кэши в Library не входят. Ссылки пропускаются; APFS-клоны могут разделять блоки."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l10n.text("Каталог охватывает стандартные папки приложений. Подсчёт ограничен временем и числом файлов; неполные размеры отмечены ≥."))
                    .font(.caption).foregroundStyle(.secondary)
                if let inventory = model.inventory {
                    Text(l10n.format("Найдено: %@ · показано: %@ · просмотрено объектов: %@", inventory.discoveredApplications.formatted(), inventory.applications.count.formatted(), inventory.visitedEntries.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(l10n.format("Список от %@ · кэш до 5 минут", inventory.capturedAt.formatted(date: .omitted, time: .standard)))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(inventory.roots.enumerated()), id: \.offset) { _, root in
                        Text(location(root.location) + ": " + rootState(root.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(8)
        }
    }
    private var inventoryStatus: some View {
        Group {
            if paused || model.suspended { Text(l10n.text("Обновление списка приостановлено")) }
            else if model.applicationSample?.state == .unavailable { Text(l10n.text("Каталог приложений недоступен")) }
            else if model.inventory == nil || model.applicationSample?.stale == true {
                HStack { ProgressView().controlSize(.small); Text(l10n.text("Подсчёт размеров приложений…")) }
            } else if let inventory = model.inventory, !inventory.enumerationComplete || inventory.applications.contains(where: { !$0.complete }) {
                Label(l10n.text("Список получен частично"), systemImage: "exclamationmark.circle")
            } else { Text(l10n.text("Сканирование завершено")) }
        }.font(.callout)
    }
    private var refreshButton: some View {
        Button(l10n.text("Обновить список"), systemImage: "arrow.clockwise") { Task { await model.refreshApplications() } }
            .disabled(paused || model.suspended || model.refreshing || model.inventory == nil)
    }
    private var sortPicker: some View {
        Picker(l10n.text("Сортировка"), selection: $model.sort) {
            Text(l10n.text("По размеру файлов")).tag(DiskApplicationSort.logical)
            Text(l10n.text("По месту на диске")).tag(DiskApplicationSort.allocated)
            Text(l10n.text("По имени")).tag(DiskApplicationSort.name)
        }.pickerStyle(.menu)
    }
    private func location(_ value: ApplicationLocation) -> String {
        switch value { case .system: l10n.text("Системные приложения"); case .shared: l10n.text("Общие приложения"); case .user: l10n.text("Приложения пользователя") }
    }
    private func rootState(_ value: ApplicationRootState) -> String {
        switch value {
        case .readable: l10n.text("Папка прочитана")
        case .missing: l10n.text("Папка отсутствует")
        case .inaccessible: l10n.text("Папка недоступна")
        case .symbolicLink: l10n.text("Символьная ссылка пропущена")
        }
    }
}
