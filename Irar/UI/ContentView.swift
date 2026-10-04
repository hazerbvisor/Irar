// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

private enum Destination: String, CaseIterable, Identifiable, Hashable {
    case archives = "Archives", extracted = "Extracted", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self { case .archives: "archivebox"; case .extracted: "folder"; case .about: "info.circle" }
    }
}
@MainActor struct ContentView: View {
    @State private var model = AppModel()
    @State private var destination: Destination? = .archives
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var importer = false
    @State private var path: [URL] = []
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(selection: Binding(get: { destination }, set: { destination = $0; path = [] })) {
                ForEach(Destination.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }.navigationTitle("Irar")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            NavigationStack(path: $path) {
                switch destination ?? .archives {
                case .archives:
                    StorageBrowser(model: model, folder: model.store.imports, archives: true)
                        .navigationTitle("Archives")
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { importButton } }
                case .extracted:
                    StorageBrowser(model: model, folder: model.store.extracted, archives: false)
                        .navigationTitle("Extracted")
                case .about: AboutView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            if model.importing {
                ImportStatus(progress: model.progress, cancel: model.cancelImport)
                    .padding().background(.regularMaterial)
            }
        }
        .task { await model.prepare() }
        .onChange(of: model.output) {
            if let folder = model.output {
                destination = .extracted; path = [folder]; model.output = nil
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { model.importArchives(try result.get()) }
            catch { model.error = error.localizedDescription }
        }
        .alert("Irar", isPresented: Binding(get: { model.error != nil || model.message != nil }, set: { if !$0 { model.error = nil; model.message = nil } })) {
            Button("OK", role: .cancel) { model.error = nil; model.message = nil }
        } message: { Text(model.error ?? model.message ?? "") }
    }
    private var importButton: some View {
        Button("Import Archives", systemImage: "square.and.arrow.down") { importer = true }
            .disabled(model.importing)
    }
}
private struct ImportStatus: View {
    let progress: ImportProgress
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Importing").font(.headline); Spacer(); Button("Cancel", action: cancel) }
            Text(progress.filename).font(.caption).lineLimit(1)
            if let total = progress.total, total > 0 { ProgressView(value: min(1, Double(progress.bytes) / Double(total))) }
            else { ProgressView() }
            Text(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file) + " copied").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: 640)
    }
}

@MainActor struct StorageBrowser: View {
    let model: AppModel
    let folder: URL
    let archives: Bool
    @State private var files: [StoredFile] = []
    @State private var archive: StoredFile?
    @State private var deleting: StoredFile?
    @State private var exporting: StoredFile?
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if files.isEmpty && error == nil {
                ContentUnavailableView(archives ? "Your archives, unpacked" : "Ready when you are",
                    systemImage: archives ? "archivebox" : "folder",
                    description: Text(archives ? "Import RAR, RAR5 or ZIP files from Files. For a multipart archive, select every volume together." : "Extract an archive to browse its files here. You can export a file or a whole folder to Files."))
            }
            ForEach(files) { file in
                FileRow(file: file, archives: archives,
                        open: { archive = file }, export: { exporting = file }, delete: { deleting = file })
            }
        }
        .navigationDestination(for: URL.self) { folder in
            StorageBrowser(model: model, folder: folder, archives: false).navigationTitle(folder.lastPathComponent)
        }
        .refreshable { await load() }
        .task(id: model.revision) { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.labelStyle(.iconOnly)
            }
        }
        .sheet(item: $archive, onDismiss: { model.revision += 1 }) { item in
            ArchiveDetailsView(archive: item, store: model.store) { folder in
                // Present the result after the details sheet dismisses.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.output = folder }
            }
        }
        .sheet(item: $exporting) { file in ExportPicker(urls: [file.url]) }
        .confirmationDialog("Delete \(deleting?.name ?? "this item")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { file in
            Button("Delete", role: .destructive) { deleting = nil; Task { await model.delete(file) } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in Text("This removes the item from Irar, including the contents of a folder. The original imported archive in Files is kept.") }
    }
    private func load() async {
        let store = model.store, folder = folder
        do {
            files = try await Task.detached {
                try store.prepare()
                return try store.list(folder)
            }.value
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
private struct FileRow: View {
    let file: StoredFile
    let archives: Bool
    let open: () -> Void
    let export: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack {
            if file.directory {
                NavigationLink(value: file.url) { contents }
            } else {
                Button(action: file.archive ? open : export) { contents }
            }
            Menu {
                Button("Save to Files", systemImage: "square.and.arrow.up", action: export)
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
            } label: { Label("Options for \(file.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
        }.padding(.vertical, 4)
    }
    private var contents: some View {
        HStack(spacing: 12) {
            Image(systemName: file.directory ? "folder.fill" : (file.archive ? "archivebox.fill" : "doc"))
                .font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).foregroundStyle(.primary).lineLimit(2)
                Text(file.directory ? "Folder" : "\(file.url.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
    }
}
