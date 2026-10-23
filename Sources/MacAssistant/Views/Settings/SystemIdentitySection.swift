import SwiftUI
import EcosystemLocalization
import MacAssistantCore

struct SystemIdentitySection: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: SystemIdentityViewModel
    private var l10n: AthenaLocalization { .init(language: language) }
    var body: some View {
        Section(l10n.text("Этот Mac")) {
            if let info = model.info { SystemIdentityRows(info: info) }
            else if model.loading { ProgressView(l10n.text("Сведения о Mac")) }
            else { Text(l10n.text("Нет данных")).foregroundStyle(.secondary) }
            if let error = model.error { Text(l10n.render(.runtime(error))).foregroundStyle(.secondary) }
            Button(l10n.text("Обновить сведения о Mac"), systemImage: "arrow.clockwise") {
                Task { await model.load(force: true) }
            }.disabled(model.loading)
        }.task { await model.load() }
    }
}

/// Внешние model/version/architecture остаются данными, а не ключами перевода.
struct SystemIdentityRows: View {
    @Environment(\.agentLanguage) private var language
    let info: SystemInfo
    private var l10n: AthenaLocalization { .init(language: language) }
    var body: some View {
        LabeledContent(l10n.text("Модель"), value: info.modelName)
        LabeledContent("macOS", value: info.operatingSystemVersion)
        LabeledContent(l10n.text("Архитектура"), value: info.architecture)
        LabeledContent(l10n.text("Ядра CPU"), value: l10n.format("%@ физических / %@ логических", String(info.physicalCPUCoreCount), String(info.logicalCPUCoreCount)))
    }
}
