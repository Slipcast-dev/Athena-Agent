import SwiftUI
import EcosystemLocalization
import EcosystemUI
import MacAssistantCore

struct FolderAnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    @StateObject private var viewModel: FolderAnalysisViewModel

    init(storage: any StorageAnalyzing) {
        _viewModel = StateObject(wrappedValue: FolderAnalysisViewModel(storage: storage))
    }
    init(viewModel: FolderAnalysisViewModel) { _viewModel = StateObject(wrappedValue: viewModel) }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(12)
            Divider()
            FeatureScreen(title: l10n.text("Крупные файлы"), state: viewModel.presentedState(language: language)) { results }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text(l10n.text("Показываются до 1000 файлов от 100 МиБ. Недоступные файлы и символьные ссылки пропускаются; содержимое пакетов не анализируется."))
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .safeAreaInset(edge: .bottom) {
            if let directory = viewModel.selectedDirectory {
                Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(8)
            }
        }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder private var results: some View {
        if viewModel.selectedDirectory == nil {
            ContentUnavailableView(l10n.text("Каталог для анализа не выбран"), systemImage: "internaldrive",
                description: Text(l10n.text("Выберите пользовательский каталог. Файлы не будут изменены.")))
        } else if viewModel.cancelled {
            ContentUnavailableView(l10n.text("Ожидание анализа прекращено"), systemImage: "pause.circle",
                description: Text(l10n.text("Фоновую задачу можно проверить и остановить в настройках, в списке задач.")))
        } else if viewModel.items.isEmpty {
            ContentUnavailableView(l10n.text("Крупные файлы не найдены"), systemImage: "doc")
        } else {
            List(viewModel.items) { item in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.url.lastPathComponent)
                        Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(DiskFormat.bytes(item.sizeBytes, language: language)).monospacedDigit()
                }.accessibilityElement(children: .combine)
            }
        }
    }

    /// Кнопки входят в содержимое sheet: доступны даже без NavigationStack
    /// и не зависят от toolbar родительского окна раздела «Диск».
    private var controls: some View {
        HStack {
            Text(l10n.text("Крупные файлы")).font(.headline)
            Spacer()
            Button(l10n.text("Выбрать каталог"), systemImage: "folder") { viewModel.chooseAndScanDirectory(language: language) }
                .keyboardShortcut("o", modifiers: .command)
            if viewModel.state == .loading {
                Button(l10n.text("Прекратить ожидание"), systemImage: "xmark") { viewModel.cancel() }
            }
            Button(l10n.text("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}
