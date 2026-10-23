import CryptoKit
import Darwin
import Foundation

public struct ApplicationScanRoot: Sendable {
    public let url: URL
    public let location: ApplicationLocation
    public init(url: URL, location: ApplicationLocation) { self.url = url; self.location = location }
    public static var standard: [Self] {
        [.init(url: URL(fileURLWithPath: "/Applications"), location: .shared),
         .init(url: URL(fileURLWithPath: "/System/Applications"), location: .system),
         .init(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), location: .user)]
    }
}
public struct ApplicationScanLimits: Sendable {
    public let maximumEntries: Int
    public let maximumApplications: Int
    public let discoveryDepth: Int
    public let bundleDepth: Int
    public let maximumSeconds: Double
    public init(maximumEntries: Int = 1_000_000, maximumApplications: Int = 256,
                discoveryDepth: Int = 8, bundleDepth: Int = 64, maximumSeconds: Double = 60) {
        self.maximumEntries = min(1_000_000, max(1, maximumEntries))
        self.maximumApplications = min(256, max(1, maximumApplications))
        self.discoveryDepth = min(32, max(0, discoveryDepth)); self.bundleDepth = min(64, max(0, bundleDepth))
        self.maximumSeconds = maximumSeconds.isFinite ? min(60, max(0.001, maximumSeconds)) : 60
    }
}

/// Каждый переход привязан к уже открытому FD. O_NOFOLLOW проверяется ядром
/// при openat: замена каталога ссылкой между fstatat и openat не выпускает обход
/// за пределы открытого дерева. Обычный URL enumerator этого не гарантирует.
public struct POSIXApplicationInventoryScanner: ApplicationInventoryScanning {
    private let roots: [ApplicationScanRoot]
    private let limits: ApplicationScanLimits
    private let clock: MonitoringClock
    public init(roots: [ApplicationScanRoot] = ApplicationScanRoot.standard,
                limits: ApplicationScanLimits = .init(), clock: MonitoringClock = .live) {
        self.roots = Array(roots.prefix(16)); self.limits = limits; self.clock = clock
    }
    public func scan() async throws -> ApplicationInventoryMetrics {
        try Task.checkCancellation()
        let state = ScanState(limits: limits, clock: clock)
        var rows: [InstalledApplicationMetrics] = [], coverage: [ApplicationRootCoverage] = []
        for root in roots {
            try Task.checkCancellation()
            if state.stopped { break }
            do {
                let handle = try DirectoryHandle.absolute(root.url)
                // Передаём вниз raw FD; lifetime владельца обязан пережить
                // async-вызов и в оптимизированной сборке с ранним ARC release.
                defer { withExtendedLifetime(handle) {} }
                coverage.append(.init(location: root.location, state: .readable))
                try await discover(handle.raw, root: root, relative: [], depth: 0, state: state, rows: &rows)
            } catch let issue as RootIssue {
                coverage.append(.init(location: root.location, state: issue.state))
                if issue.state != .missing { state.discoveryComplete = false }
            }
        }
        return ApplicationInventoryMetrics(capturedAt: clock.now().date, applications: rows.sorted {
            let left = $0.logicalBytes.value ?? 0, right = $1.logicalBytes.value ?? 0
            return left == right ? $0.id < $1.id : left > right
        }, roots: coverage, discoveredApplications: state.discovered, visitedEntries: state.entries,
            enumerationComplete: state.discoveryComplete && !state.stopped && coverage.count == roots.count,
            limitReached: state.stopped)
    }

    private func discover(_ fd: Int32, root: ApplicationScanRoot, relative: [String], depth: Int,
                          state: ScanState, rows: inout [InstalledApplicationMetrics]) async throws {
        guard let listing = DirectoryListing(fd) else { state.discoveryComplete = false; return }
        while !state.stopped {
            try Task.checkCancellation()
            guard let name = listing.next() else { if listing.failed { state.discoveryComplete = false }; break }
            if name == "." || name == ".." { continue }
            guard try state.visit() else { break }
            if state.entries % 128 == 0 { await Task.yield() }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { state.discoveryComplete = false; continue }
            if (info.st_mode & S_IFMT) == S_IFLNK { state.discoveryComplete = false; continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let isApp = name.lowercased().hasSuffix(".app")
            if isApp {
                // Один bundle включает собственные вложенные Helper.app. Не
                // создаём для них отдельные строки и не суммируем bundle дважды.
                guard state.bundles.insert(FileIdentity(info)).inserted else { continue }
                state.discovered += 1
                guard rows.count < limits.maximumApplications else { state.stopped = true; break }
                let identity = root.url.path + "/" + (relative + [name]).joined(separator: "/")
                let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                var size = BundleSize(), seen = Set<FileIdentity>()
                if let child = DirectoryHandle.child(fd, name: name) {
                    defer { withExtendedLifetime(child) {} }
                    try await measure(child.raw, depth: 0, state: state, size: &size, seen: &seen)
                } else { size.complete = false; size.errors += 1 }
                let known = size.complete || size.files > 0
                rows.append(.init(id: id, name: MountedDiskVolumeReader.bounded(String(name.dropLast(4)), maximum: 256),
                    location: root.location, logicalBytes: .init(known ? size.logical : nil),
                    allocatedBytes: .init(known ? size.allocated : nil), complete: size.complete,
                    inaccessibleEntries: size.errors, skippedSymbolicLinks: size.links))
            } else if depth < limits.discoveryDepth, let child = DirectoryHandle.child(fd, name: name) {
                defer { withExtendedLifetime(child) {} }
                try await discover(child.raw, root: root, relative: relative + [name], depth: depth + 1, state: state, rows: &rows)
            } else { state.discoveryComplete = false; if depth >= limits.discoveryDepth { state.stopped = true } }
        }
    }

    private func measure(_ fd: Int32, depth: Int, state: ScanState, size: inout BundleSize,
                         seen: inout Set<FileIdentity>) async throws {
        guard let listing = DirectoryListing(fd) else { size.complete = false; size.errors += 1; return }
        while !state.stopped {
            try Task.checkCancellation()
            guard let name = listing.next() else { if listing.failed { size.complete = false; size.errors += 1 }; break }
            if name == "." || name == ".." { continue }
            guard try state.visit() else { size.complete = false; break }
            if state.entries % 128 == 0 { await Task.yield() }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { size.complete = false; size.errors += 1; continue }
            switch info.st_mode & S_IFMT {
            case S_IFLNK: size.links += 1 // ссылки не раскрываем, даже если цель внутри bundle
            case S_IFDIR:
                if depth < limits.bundleDepth, let child = DirectoryHandle.child(fd, name: name) {
                    defer { withExtendedLifetime(child) {} }
                    try await measure(child.raw, depth: depth + 1, state: state, size: &size, seen: &seen)
                } else {
                    size.complete = false; size.errors += 1
                    if depth >= limits.bundleDepth { state.stopped = true }
                }
            case S_IFREG:
                // Hard links внутри одного bundle считаем один раз по device/inode.
                // Между приложениями размер не является уникальным физическим вкладом.
                guard seen.insert(FileIdentity(info)).inserted else { continue }
                guard info.st_size >= 0, info.st_blocks >= 0 else { size.complete = false; size.errors += 1; continue }
                let allocated = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
                let logical = size.logical.addingReportingOverflow(UInt64(info.st_size))
                let blocks = size.allocated.addingReportingOverflow(allocated.partialValue)
                guard !allocated.overflow, !logical.overflow, !blocks.overflow else { size.complete = false; size.errors += 1; continue }
                size.logical = logical.partialValue; size.allocated = blocks.partialValue; size.files += 1
            default: break // FIFO/socket/device не открываем и не читаем
            }
        }
        if state.stopped { size.complete = false }
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
}
private struct BundleSize {
    var logical: UInt64 = 0, allocated: UInt64 = 0
    var files = 0, errors = 0, links = 0
    var complete = true
}
private final class ScanState {
    let limits: ApplicationScanLimits, clock: MonitoringClock
    let started: Double
    var entries = 0, discovered = 0
    var stopped = false, discoveryComplete = true
    var bundles = Set<FileIdentity>()
    init(limits: ApplicationScanLimits, clock: MonitoringClock) {
        self.limits = limits; self.clock = clock; started = clock.now().monotonic
    }
    func visit() throws -> Bool {
        try Task.checkCancellation()
        let age = clock.now().monotonic - started
        guard entries < limits.maximumEntries, age >= 0, age < limits.maximumSeconds else { stopped = true; return false }
        entries += 1; return true
    }
}
private struct RootIssue: Error {
    let state: ApplicationRootState
    init(_ state: ApplicationRootState) { self.state = state }
}
private final class DirectoryHandle {
    let raw: Int32
    init(_ raw: Int32) { self.raw = raw }
    deinit { close(raw) }
    static func child(_ parent: Int32, name: String) -> DirectoryHandle? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? DirectoryHandle(fd) : nil
    }
    static func absolute(_ url: URL) throws -> DirectoryHandle {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw RootIssue(.inaccessible) }
        var current = DirectoryHandle(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        guard current.raw >= 0 else { throw RootIssue(.inaccessible) }
        for component in url.path.split(separator: "/").map(String.init) {
            guard component != ".", component != ".." else { throw RootIssue(.inaccessible) }
            var info = stat()
            guard fstatat(current.raw, component, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RootIssue(errno == ENOENT ? .missing : .inaccessible)
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw RootIssue(.symbolicLink) }
            guard let next = child(current.raw, name: component) else { throw RootIssue(.inaccessible) }
            current = next
        }
        return current
    }
}
private final class DirectoryListing {
    private let stream: UnsafeMutablePointer<DIR>
    private(set) var failed = false
    init?(_ fd: Int32) {
        // fdopendir владеет переданным FD; отдельная CLOEXEC-копия не меняет
        // срок жизни directory handle родительского openat.
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        self.stream = stream
    }
    deinit { closedir(stream) }
    func next() -> String? {
        errno = 0
        guard let entry = readdir(stream) else { failed = errno != 0; return nil }
        let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix { $0 != 0 }) }
        guard let name = String(bytes: bytes, encoding: .utf8) else { failed = true; return nil }
        return name
    }
}
