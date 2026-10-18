import Foundation

/// Безопасный, отменяемый анализатор только выбранного каталога. Он никогда не
/// изменяет файлы и не пытается обойти разрешения TCC: недоступные элементы просто пропускаются.
public actor StorageAnalysisService: StorageAnalyzing {
    private let fileManager: FileManager
    private let maximumResults: Int

    public init(fileManager: FileManager = .default, maximumResults: Int = 1_000) {
        self.fileManager = fileManager
        self.maximumResults = maximumResults
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

        var items: [StorageItem] = []
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
            items.append(StorageItem(url: candidate, sizeBytes: UInt64(size), modifiedAt: values.contentModificationDate, isDirectory: false))
        }

        return Array(items.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(maximumResults))
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
