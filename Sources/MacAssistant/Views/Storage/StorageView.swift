import SwiftUI
import MacAssistantCore

struct StorageView: View {
    @StateObject private var viewModel: StorageViewModel

    init(container: AppContainer) {
        _viewModel = StateObject(wrappedValue: StorageViewModel(storage: container.services.storage))
    }

    var body: some View {
        FeatureScreen(title: "Накопитель", state: viewModel.state) {
            Group {
                if viewModel.selectedDirectory == nil {
                    ContentUnavailableView("Каталог для анализа не выбран", systemImage: "internaldrive", description: Text("Выберите пользовательский каталог. Файлы не будут изменены."))
                } else if viewModel.items.isEmpty {
                    ContentUnavailableView("Крупные файлы не найдены", systemImage: "doc", description: Text("Показываются файлы от 100 МБ."))
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
            Button("Выбрать каталог", systemImage: "folder") { viewModel.chooseAndScanDirectory() }
                .keyboardShortcut("o", modifiers: .command)
            if viewModel.state == .loading {
                Button("Отменить", systemImage: "xmark") { viewModel.cancel() }
            }
        }
    }
}
