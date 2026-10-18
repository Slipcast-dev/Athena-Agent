import Darwin
import Foundation
import EcosystemLocalIPC

/// В локальном профиле persistent bookmarks принадлежат только runtime.
/// Revocation переживает перезапуск; права не восстанавливаются по строке пути.
public actor AthenaLocalGrants {
    private struct Entry: Codable { var bookmark: Data?; var revision: Int64 }
    private struct Document: Codable { let version: Int; var entries: [String: Entry] }
    private let file: URL
    private var document: Document
    public init(directory: URL) throws {
        file = directory.appendingPathComponent("grants-v1.json")
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 1_048_576 else { throw LocalRuntimeFailure.invalidConfiguration }
            document = try LocalWire.decode(Document.self, Data(contentsOf: file), keys: ["version", "entries"])
            guard document.version == 1, document.entries.count <= 128 else { throw LocalRuntimeFailure.invalidConfiguration }
        } else { document = Document(version: 1, entries: [:]) }
    }
    func add(_ transfer: AthenaRootTransfer) throws -> UUID {
        var stale = false
        let url = try URL(resolvingBookmarkData: transfer.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.startAccessingSecurityScopedResource() else { throw LocalRuntimeFailure.denied }
        defer { url.stopAccessingSecurityScopedResource() }
        _ = try StoragePathValidator.validatedDirectory(url)
        // Повторный выбор той же ещё разрешённой папки не расходует новый слот.
        // После отзыва создаётся новое явное разрешение, старое не оживает.
        for (key, entry) in document.entries where entry.bookmark != nil {
            if let id = UUID(uuidString: key), let current = try? resolve(id),
               current.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path { return id }
        }
        guard document.entries.count < 128 else { throw LocalRuntimeFailure.busy }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = UUID()
        var next = document; next.entries[id.uuidString] = Entry(bookmark: bookmark, revision: 1)
        try persist(next); document = next
        return id
    }
    func resolve(_ id: UUID) throws -> URL {
        guard let bookmark = document.entries[id.uuidString]?.bookmark else { throw LocalRuntimeFailure.denied }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw LocalRuntimeFailure.denied }
        return try StoragePathValidator.validatedDirectory(url)
    }
    func contains(_ id: UUID) -> Bool { document.entries[id.uuidString]?.bookmark != nil }
    func revoke(_ id: UUID) throws {
        guard var entry = document.entries[id.uuidString] else { throw LocalRuntimeFailure.denied }
        guard entry.revision < Int64.max else { throw LocalRuntimeFailure.invalidConfiguration }
        entry.bookmark = nil; entry.revision += 1
        var next = document; next.entries[id.uuidString] = entry
        try persist(next); document = next
    }
    private func persist(_ value: Document) throws {
        let data = try LocalWire.encode(value)
        guard data.count <= 1_048_576 else { throw LocalRuntimeFailure.invalidRequest }
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
