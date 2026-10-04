// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation

struct ImportProgress: Sendable {
    var filename = ""
    var bytes: Int64 = 0
    var total: Int64?
}
@MainActor @Observable
final class AppModel {
    let store: FileStore
    var error: String?
    var message: String?
    var importing = false
    var progress = ImportProgress()
    var revision = 0
    var output: URL?
    private var cancellation: FileCancellation?
    init() {
        store = FileStore(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath())
    }
    func prepare() async {
        let store = store
        do { try await Task.detached { try store.prepare() }.value; revision += 1 }
        catch { self.error = error.localizedDescription }
    }
    func importArchives(_ urls: [URL]) {
        guard !importing else { return }
        // Hold provider grants from picker completion until the worker finishes.
        let picked = PickedArchives(urls)
        let store = store, token = FileCancellation()
        cancellation = token; importing = true; progress = ImportProgress()
        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) { [self] in
                    try store.prepare()
                    return try store.importFiles(picked.urls, cancellation: token) { name, bytes, total in
                        Task { @MainActor in self.progress = ImportProgress(filename: name, bytes: bytes, total: total) }
                    }
                }.value
                message = "Imported \(imported.count) \(imported.count == 1 ? "archive" : "files"). Tap an archive to see its contents and extract it."
            } catch is CancellationError { message = "Import cancelled. Completed imports were kept; the partial copy was removed." }
            catch { self.error = error.localizedDescription }
            importing = false; cancellation = nil; revision += 1
        }
    }
    func cancelImport() { cancellation?.cancel() }
    func delete(_ file: StoredFile) async {
        let store = store
        do { try await Task.detached { try store.delete(file.url) }.value; revision += 1 }
        catch { self.error = error.localizedDescription }
    }
}
private final class PickedArchives: @unchecked Sendable {
    let urls: [URL]
    let grants: [URL]
    init(_ urls: [URL]) { self.urls = urls; grants = urls.filter { $0.startAccessingSecurityScopedResource() } }
    deinit { grants.forEach { $0.stopAccessingSecurityScopedResource() } }
}

@MainActor @Observable
final class ExtractionModel {
    var report: ArchiveReport?
    var error: String?
    var busy = false
    var extracting = false
    var compressed: Int64 = 0
    var progress = ArchiveProgress(filename: "", bytes: 0, input: 0)
    var output: URL?
    private var cancellation = FileCancellation()
    func cancel() { cancellation.cancel() }
    func inspect(_ archive: StoredFile, store: FileStore) {
        perform(archive, store: store, extract: false)
    }
    func extract(_ archive: StoredFile, store: FileStore) {
        perform(archive, store: store, extract: true)
    }
    private func perform(_ archive: StoredFile, store: FileStore, extract: Bool) {
        guard !busy else { return }
        busy = true; extracting = extract; error = nil; if extract { output = nil }; progress = ArchiveProgress(filename: "", bytes: 0, input: 0)
        cancellation = FileCancellation(); let token = cancellation
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [self] () throws -> (ArchiveReport, URL?) in
                    let volumes = try store.volumes(for: archive.url)
                    await MainActor.run { self.compressed = volumes.compressedSize }
                    let folder = extract ? try store.extractionFolder(for: volumes.urls[0]) : nil
                    if let folder { await MainActor.run { self.output = folder } }
                    let report = try ArchiveService.run(volumes: volumes.urls, root: store.root, destination: folder, cancellation: token) { [self] update in
                        Task { @MainActor in self.progress = update }
                    }
                    return (report, folder)
                }.value
                if let folder = result.1 { output = folder }
                else { report = result.0 }
            } catch is CancellationError {
                error = extract ? "Extraction cancelled. Completed files remain in Extracted; the incomplete file was removed." : "Inspection cancelled. Tap Retry to inspect this archive again."
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
