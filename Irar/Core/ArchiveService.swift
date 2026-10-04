// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ArchiveItem: Identifiable, Sendable {
    let name: String
    let directory: Bool
    let size: Int64
    let id = UUID()
}
struct ArchiveReport: Sendable {
    var items: [ArchiveItem] = []
    var format = "Archive"
    var total: Int64 = 0
    var knownSize = true
}
struct ArchiveProgress: Sendable {
    let filename: String
    let bytes: Int64
    let input: Int64
}
final class FileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
private final class ArchiveContext {
    let cancellation: FileCancellation
    let listing: Bool
    let progress: @Sendable (ArchiveProgress) -> Void
    var report = ArchiveReport()
    var failure: String?
    var metadataBytes = 0
    var lastUpdate = 0.0
    var currentName = ""
    init(cancellation: FileCancellation, listing: Bool, progress: @escaping @Sendable (ArchiveProgress) -> Void) {
        self.cancellation = cancellation; self.listing = listing; self.progress = progress
    }
}

enum ArchiveService {
    /// Run on a worker, never on the UI executor. libarchive owns decompression
    /// buffers; Irar holds only one 64 KiB output chunk and bounded metadata.
    static func run(volumes: [URL], root: URL? = nil, destination: URL?, cancellation: FileCancellation,
                    progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) throws -> ArchiveReport {
        let context = ArchiveContext(cancellation: cancellation, listing: destination == nil, progress: progress)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        var error = [CChar](repeating: 0, count: 2048)
        let result = irar_archive_run(volumes.map(\.path).joined(separator: "\n"), root?.path, destination?.path, { opaque, name, format, size, directory, entry, bytes, input in
            guard let opaque else { return 1 }
            let context = Unmanaged<ArchiveContext>.fromOpaque(opaque).takeUnretainedValue()
            if context.cancellation.cancelled { return 1 }
            let filename = name.map { String(cString: $0) } ?? ""
            if !filename.isEmpty { context.currentName = filename }
            if let format, format.pointee != 0, context.listing { context.report.format = String(cString: format) }
            if entry != 0 && context.listing {
                context.metadataBytes += filename.utf8.count + 160
                guard context.report.items.count < 100000, context.metadataBytes <= 32 * 1024 * 1024 else {
                    context.failure = "Archive contents exceed the preview limit (100,000 entries or 32 MiB of metadata). Split it into smaller archives."; return 1
                }
                context.report.items.append(ArchiveItem(name: filename, directory: directory != 0, size: size))
                if size < 0 { context.report.knownSize = false }
                else {
                    let (sum, overflow) = context.report.total.addingReportingOverflow(size)
                    if overflow { context.report.knownSize = false } else { context.report.total = sum }
                }
            }
            if ProcessInfo.processInfo.systemUptime - context.lastUpdate >= 0.1 {
                context.lastUpdate = ProcessInfo.processInfo.systemUptime
                context.progress(ArchiveProgress(filename: context.currentName, bytes: bytes, input: input))
            }
            return 0
        }, pointer, &error, error.count)
        if let failure = context.failure { throw ArchiveError.message(failure) }
        if result == 1 { throw CancellationError() }
        guard result == 0 else { throw ArchiveError.message(String(cString: error)) }
        return context.report
    }
}
