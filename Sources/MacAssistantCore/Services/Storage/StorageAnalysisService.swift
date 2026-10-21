import Foundation

/// Безопасный, отменяемый анализатор только выбранного каталога. Он никогда не
/// изменяет файлы и не пытается обойти разрешения TCC: недоступные элементы просто пропускаются.
public actor StorageAnalysisService: StorageAnalyzing {
    private let fileManager: FileManager
    private let maximumResults: Int

    public init(fileManager: FileManager = .default, maximumResults: Int = 1_000) {
        self.fileManager = fileManager
        self.maximumResults = max(0, maximumResults)
    }

    public func storageOverview() async throws -> StorageOverview {
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ])
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else {
            throw StorageAnalysisError.volumeInformationUnavailable
        }
        return StorageOverview(totalBytes: UInt64(total), availableBytes: UInt64(max(available, 0)))
    }

    public func scanDirectory(at url: URL, minimumSizeBytes: UInt64) async throws -> [StorageItem] {
        // Проверяем отмену до работы с файловой системой. Это особенно важно для
        // пустого каталога: без этой проверки цикл перечисления не выполнится и
        // отменённая операция ошибочно вернёт обычный пустой результат.
        try Task.checkCancellation()
        let root = try StoragePathValidator.validatedDirectory(url)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw StorageAnalysisError.cannotEnumerateDirectory
        }

        var items = LargestStorageItems(capacity: maximumResults)
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: Set(keys))
            } catch {
                // Недоступный файл не даёт приложению основания менять права или обходить TCC.
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { continue }
            guard UInt64(size) >= minimumSizeBytes else { continue }
            items.insert(StorageItem(url: candidate, sizeBytes: UInt64(size), modifiedAt: values.contentModificationDate, isDirectory: false))
        }

        return items.sorted()
    }
}

/// Проверка устраняет относительные пути и гарантирует, что сканер получает
/// существующий каталог, а не путь к файлу или потенциально ошибочную ссылку.
public enum StoragePathValidator {
    public static func validatedDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw StorageAnalysisError.invalidDirectory }
        let standardized = url.standardizedFileURL
        // Выбранная корневая ссылка может вести за пределы каталога, на который
        // пользователь дал разрешение через NSOpenPanel. В MVP такие ссылки не
        // раскрываем и не сканируем; это сохраняет понятную границу TCC.
        let values = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw StorageAnalysisError.invalidDirectory }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageAnalysisError.invalidDirectory
        }
        return standardized
    }
}

public enum StorageAnalysisError: LocalizedError, Equatable, Sendable {
    case invalidDirectory
    case cannotEnumerateDirectory
    case volumeInformationUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "Выберите существующий каталог для анализа."
        case .cannotEnumerateDirectory: "Не удалось начать сканирование выбранного каталога."
        case .volumeInformationUnavailable: "Не удалось получить сведения о системном накопителе."
        }
    }
}

/// Min-heap хранит только K лучших элементов. Равные размеры упорядочены
/// по пути: результат не зависит от порядка перечисления файловой системы.
struct LargestStorageItems {
    let capacity: Int
    private(set) var heap: [StorageItem] = []
    static func better(_ a: StorageItem, _ b: StorageItem) -> Bool {
        a.sizeBytes == b.sizeBytes ? a.url.path < b.url.path : a.sizeBytes > b.sizeBytes
    }
    mutating func insert(_ item: StorageItem) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(item)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard Self.better(heap[parent], heap[i]) else { break }
                heap.swapAt(parent, i); i = parent
            }
        } else if Self.better(item, heap[0]) {
            heap[0] = item
            var i = 0
            while 2 * i + 1 < heap.count {
                var child = 2 * i + 1
                if child + 1 < heap.count, Self.better(heap[child], heap[child + 1]) { child += 1 }
                guard Self.better(heap[i], heap[child]) else { break }
                heap.swapAt(i, child); i = child
            }
        }
    }
    func sorted() -> [StorageItem] { heap.sorted(by: Self.better) }
}
