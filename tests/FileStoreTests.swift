// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct FileStoreTests {
    static func check(_ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { fatalError("Check failed") }
    }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileStore(root: root)
        try store.prepare()
        defer { try? fm.removeItem(at: root) }
        try check(try store.list(root).map(\.name) == ["Extracted", "Imports"])
        rejects { _ = try store.checked(root.deletingLastPathComponent()) }
        rejects { _ = try store.checked(root.appendingPathComponent("../escape")) }
        rejects { _ = try store.createFolder("../escape", in: store.extracted) }
        rejects { try store.delete(store.root) }
        rejects { try store.delete(store.imports) }
        rejects { try store.delete(store.extracted) }
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: outside) }
        let link = store.imports.appendingPathComponent("linked.rar")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        rejects { _ = try store.checked(link) }
        try check(try store.list(store.imports).isEmpty)
        let source = outside.appendingPathComponent("large.rar")
        _ = fm.createFile(atPath: source.path, contents: nil)
        let file = try FileHandle(forWritingTo: source)
        for _ in 0..<1024 { try file.write(contentsOf: Data(repeating: 71, count: 65536)) }
        try file.close()
        let imported = try store.importFiles([source], cancellation: FileCancellation())
        assert(imported.count == 1)
        try check(try imported[0].resourceValues(forKeys: [.fileSizeKey]).fileSize == 64 * 1024 * 1024)
        rejects { _ = try store.importFiles([source], cancellation: FileCancellation()) }
        let stopped = FileCancellation(); stopped.cancel()
        rejects { _ = try store.importFiles([source], cancellation: stopped) }
        try store.delete(imported[0])
        assert(!fm.fileExists(atPath: imported[0].path))
        let text = outside.appendingPathComponent("text.txt")
        try Data("hi".utf8).write(to: text)
        rejects { _ = try store.importFiles([text], cancellation: FileCancellation()) }
        let symlink = outside.appendingPathComponent("bad.rar")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: source)
        rejects { _ = try store.importFiles([symlink], cancellation: FileCancellation()) }
        // Both modern and legacy part discovery, including selecting a later part.
        for name in ["game.part01.rar", "game.part02.rar", "game.part03.rar", "legacy.rar", "legacy.r00", "legacy.r01"] {
            try Data([1, 2]).write(to: store.imports.appendingPathComponent(name))
        }
        let parts = try store.volumes(for: store.imports.appendingPathComponent("game.part02.rar"))
        assert(parts.urls.map(\.lastPathComponent) == ["game.part01.rar", "game.part02.rar", "game.part03.rar"])
        assert(parts.compressedSize == 6)
        let legacy = try store.volumes(for: store.imports.appendingPathComponent("legacy.r01"))
        assert(legacy.urls.map(\.lastPathComponent) == ["legacy.rar", "legacy.r00", "legacy.r01"])
        try fm.removeItem(at: parts.urls[1])
        rejects { _ = try store.volumes(for: parts.urls[0]) }
        try Data().write(to: store.imports.appendingPathComponent("legacy.r03"))
        rejects { _ = try store.volumes(for: legacy.urls[0]) }
        let first = try store.extractionFolder(for: store.imports.appendingPathComponent("game.part01.rar"))
        let second = try store.extractionFolder(for: store.imports.appendingPathComponent("game.part01.rar"))
        assert(first != second)
        try check(try store.checked(first).path.hasPrefix(store.extracted.path + "/"))
        _ = try store.extractionFolder(for: store.imports.appendingPathComponent(String(repeating: "好", count: 80) + ".rar"))
        if CommandLine.arguments.count > 1 {
            let archive = URL(fileURLWithPath: CommandLine.arguments[1])
            let report = try ArchiveService.run(volumes: [archive], destination: nil, cancellation: FileCancellation())
            assert(report.items.count == 2 && report.total == 7 && report.knownSize)
            assert(report.format.contains("ZIP"))
            _ = try ArchiveService.run(volumes: [archive], root: root, destination: first, cancellation: FileCancellation())
            try check(try Data(contentsOf: first.appendingPathComponent("data")) == Data("hello".utf8))
            rejects { _ = try ArchiveService.run(volumes: [archive], root: root, destination: first, cancellation: FileCancellation()) }
            rejects { _ = try ArchiveService.run(volumes: [archive], destination: nil, cancellation: stopped) }
        }
        print("PASS: navigation, containment, links, 64 MiB streaming import, duplicates, cancellation, deletion, unique/Unicode output folders, modern/legacy volumes, Swift/C metadata and extraction")
    }
}
