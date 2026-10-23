import SwiftUI
import EcosystemLocalization
import EcosystemUI
import MacAssistantCore

struct StorageView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    @StateObject private var viewModel: StorageViewModel

    init(container: AppContainer) {
        _viewModel = StateObject(wrappedValue: StorageViewModel(storage: container.services.storage))
    }

    init(viewModel: StorageViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        FeatureScreen(title: l10n.text("Накопитель"), state: viewModel.presentedState(language: language)) {
            Group {
                if viewModel.selectedDirectory == nil {
                    ContentUnavailableView(l10n.text("Каталог для анализа не выбран"), systemImage: "internaldrive", description: Text(l10n.text("Выберите пользовательский каталог. Файлы не будут изменены.")))
                } else if viewModel.items.isEmpty {
                    ContentUnavailableView(l10n.text("Крупные файлы не найдены"), systemImage: "doc", description: Text(l10n.text("Показываются файлы от 100 МБ.")))
                } else {
                    List(viewModel.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent)
                            Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.sizeBytes), countStyle: .file)).monospacedDigit()
                    }
                }
            }
        }
        .toolbar {
            Button(l10n.text("Выбрать каталог"), systemImage: "folder") { viewModel.chooseAndScanDirectory(language: language) }
                .keyboardShortcut("o", modifiers: .command)
            if viewModel.state == .loading {
                Button(l10n.text("Отменить"), systemImage: "xmark") { viewModel.cancel() }
            }
        }
    }
}
