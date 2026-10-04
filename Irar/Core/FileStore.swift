// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ArchiveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct StoredFile: Identifiable, Sendable {
    let url: URL
    let directory: Bool
    let size: Int64
    let modified: Date
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var archive: Bool { FileStore.isArchiveName(name) }
}
struct ArchiveVolumes: Sendable {
    let urls: [URL]
    let compressedSize: Int64
}

struct FileStore: Sendable {
    let root: URL
    var imports: URL { root.appendingPathComponent("Imports", isDirectory: true) }
    var extracted: URL { root.appendingPathComponent("Extracted", isDirectory: true) }
    private var fm: FileManager { .default }
    func prepare() throws {
        for folder in [root, imports, extracted] {
            if fm.fileExists(atPath: folder.path) { _ = try checked(folder) }
            else { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        }
    }
    func checked(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL
        let base = root.standardizedFileURL.path
        guard path.path == base || path.path.hasPrefix(base + "/") else {
            throw ArchiveError.message("Choose a location inside Irar.")
        }
        var component = path
        while true {
            let value = try component.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard value.isSymbolicLink != true else { throw ArchiveError.message("Symbolic links cannot be opened.") }
            if component.path == base { break }
            component.deleteLastPathComponent()
        }
        let resolved = path.resolvingSymlinksInPath().path
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            throw ArchiveError.message("This location leaves Irar's storage.")
        }
        return path
    }
    func child(_ name: String, in folder: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw ArchiveError.message("Use a name without path separators or control characters (up to 240 bytes).")
        }
        return try checked(folder).appendingPathComponent(name)
    }
    func list(_ folder: URL) throws -> [StoredFile] {
        let folder = try checked(folder)
        return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]).compactMap { url in
            let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard value.isSymbolicLink != true, value.isDirectory == true || value.isRegularFile == true else { return nil }
            return StoredFile(url: try checked(url), directory: value.isDirectory == true,
                              size: Int64(value.fileSize ?? 0), modified: value.contentModificationDate ?? .distantPast)
        }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func createFolder(_ name: String, in folder: URL) throws -> URL {
        let url = try child(name, in: folder)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func extractionFolder(for archive: URL) throws -> URL {
        // A new destination for each run avoids unexpected overwrite/merge.
        let name = archive.deletingPathExtension().lastPathComponent
        var safeName = String(name.prefix(80))
        while safeName.utf8.count > 120 { safeName.removeLast() }
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return try createFolder("\(safeName)-\(date)-\(UUID().uuidString.prefix(8))", in: extracted)
    }
    func delete(_ url: URL) throws {
        let source = try checked(url)
        guard ![root.path, imports.path, extracted.path].contains(source.path) else {
            throw ArchiveError.message("Irar's storage folders cannot be deleted.")
        }
        try fm.removeItem(at: source)
    }
    static func isArchiveName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["rar", "zip"].contains(ext) { return true }
        return ext.count == 3 && ext.first == "r" && ext.dropFirst().allSatisfy(\.isNumber)
    }
    /// Imported names stay unchanged to preserve relationships between volumes.
    /// Existing archives are never replaced; remove a previous import explicitly.
    func importFiles(_ urls: [URL], cancellation: FileCancellation,
                     progress: @Sendable (String, Int64, Int64?) -> Void = { _, _, _ in }) throws -> [URL] {
        var result: [URL] = []
        for source in urls {
            if cancellation.cancelled { throw CancellationError() }
            guard Self.isArchiveName(source.lastPathComponent) else {
                throw ArchiveError.message("Import .rar, .zip or .r00/.r01 RAR volumes.")
            }
            #if canImport(Darwin)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            var imported: URL?
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { ready in
                do { imported = try copyArchive(ready, name: source.lastPathComponent, cancellation: cancellation, progress: progress) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            guard let imported else { throw ArchiveError.message("The file provider did not make this archive available.") }
            result.append(imported)
            #else
            result.append(try copyArchive(source, name: source.lastPathComponent, cancellation: cancellation, progress: progress))
            #endif
        }
        return result
    }
    private func copyArchive(_ source: URL, name: String, cancellation: FileCancellation,
                             progress: @Sendable (String, Int64, Int64?) -> Void) throws -> URL {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw ArchiveError.message("Only regular archive files can be imported.")
        }
        let target = try child(name, in: imports)
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw ArchiveError.message("Cannot read \(name): \(String(cString: strerror(errno)))") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        let outputFD = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard outputFD >= 0 else {
            if errno == EEXIST { throw ArchiveError.message("\(name) is already imported. Delete the old import first; existing files are never overwritten.") }
            throw ArchiveError.message("Cannot import \(name): \(String(cString: strerror(errno)))")
        }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        let total = values.fileSize.map(Int64.init)
        var bytes: Int64 = 0
        var lastUpdate = 0.0
        do {
            while true {
                if cancellation.cancelled { throw CancellationError() }
                let data = try input.read(upToCount: 65536) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data); bytes += Int64(data.count)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.1 { lastUpdate = now; progress(name, bytes, total) }
            }
            try output.close()
            progress(name, bytes, total)
        } catch { try? output.close(); try? fm.removeItem(at: target); throw error }
        return target
    }
    func volumes(for archive: URL) throws -> ArchiveVolumes {
        let archive = try checked(archive)
        let siblings = try list(archive.deletingLastPathComponent()).filter { !$0.directory }
        let name = archive.lastPathComponent as NSString
        let expression = try NSRegularExpression(pattern: "^(.*)\\.part([0-9]+)\\.rar$", options: .caseInsensitive)
        var ordered: [URL] = []
        if let match = expression.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)) {
            let base = name.substring(with: match.range(at: 1))
            var parts: [(Int, URL)] = []
            for item in siblings {
                let candidate = item.name as NSString
                if let found = expression.firstMatch(in: item.name, range: NSRange(location: 0, length: candidate.length)),
                   candidate.substring(with: found.range(at: 1)).caseInsensitiveCompare(base) == .orderedSame,
                   let number = Int(candidate.substring(with: found.range(at: 2))) { parts.append((number, item.url)) }
            }
            parts.sort { $0.0 < $1.0 }
            guard parts.enumerated().allSatisfy({ $0.element.0 == $0.offset + 1 }) else {
                throw ArchiveError.message("Missing or duplicate RAR volumes. Import every part starting with part1.rar.")
            }
            ordered = parts.map(\.1)
        } else if archive.pathExtension.lowercased() == "rar" || archive.pathExtension.lowercased().hasPrefix("r") {
            let stem = archive.deletingPathExtension().lastPathComponent
            let initial = siblings.filter { $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame && $0.url.pathExtension.lowercased() == "rar" }
            var rest: [(Int, URL)] = []
            for item in siblings where item.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame {
                let ext = item.url.pathExtension.lowercased()
                if ext.count == 3, ext.first == "r", let number = Int(ext.dropFirst()) { rest.append((number, item.url)) }
            }
            rest.sort { $0.0 < $1.0 }
            guard initial.count == 1, rest.enumerated().allSatisfy({ $0.element.0 == $0.offset }) else {
                throw ArchiveError.message("Missing or duplicate RAR volumes. Import the .rar file and every .r00/.r01 part.")
            }
            ordered = initial.map(\.url) + rest.map(\.1)
        } else { ordered = [archive] }
        var compressed: Int64 = 0
        for url in ordered {
            guard !url.path.contains("\n") else { throw ArchiveError.message("Archive paths cannot contain newlines.") }
            let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let (sum, overflow) = compressed.addingReportingOverflow(bytes)
            guard !overflow else { throw ArchiveError.message("The combined archive size is too large.") }
            compressed = sum
        }
        return ArchiveVolumes(urls: ordered, compressedSize: compressed)
    }
}
