// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor struct ArchiveDetailsView: View {
    let archive: StoredFile
    let store: FileStore
    let openOutput: (URL) -> Void
    @State private var model = ExtractionModel()
    @State private var exporting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "archivebox.fill").font(.system(size: 36)).foregroundStyle(.tint)
                        Text(archive.name).font(.title2.bold()).textSelection(.enabled)
                        Text(model.report?.format ?? (model.busy ? "Reading archive…" : "Archive"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    LabeledContent("Archive size", value: ByteCountFormatter.string(fromByteCount: model.compressed, countStyle: .file))
                    if let report = model.report {
                        LabeledContent("Extracted size", value: report.knownSize ? ByteCountFormatter.string(fromByteCount: report.total, countStyle: .file) : "Unknown")
                        LabeledContent("Items", value: "\(report.items.count)")
                    }
                }
                if model.busy { progressSection }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if !model.busy && model.report == nil { Button("Retry") { model.inspect(archive, store: store) } }
                    }
                }
                if !model.busy {
                    if let output = model.output {
                        Section(model.error == nil ? "Extraction complete" : "Partial extraction") {
                            Button("Browse Files", systemImage: "folder") { openOutput(output); dismiss() }
                            Button("Save Folder to Files", systemImage: "square.and.arrow.up") { exporting = true }
                            Text(output.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.report != nil {
                        Section {
                            Button(model.output == nil ? "Extract Archive" : "Extract Again", systemImage: "arrow.down.doc") {
                                model.extract(archive, store: store)
                            }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).padding(.vertical, 8)
                        } footer: {
                            Text("Each extraction creates a new folder in Irar. Existing files are never overwritten.")
                        }
                    }
                }
                if let report = model.report {
                    Section("Contents") {
                        ForEach(report.items) { item in
                            HStack {
                                Label(item.name, systemImage: item.directory ? "folder" : "doc").lineLimit(2)
                                Spacer()
                                if !item.directory { Text(item.size < 0 ? "Unknown" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }.navigationTitle("Archive")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(model.busy) } }
                .task { if model.report == nil && model.error == nil { model.inspect(archive, store: store) } }
                .sheet(isPresented: $exporting) { if let output = model.output { ExportPicker(urls: [output]) } }
        }.interactiveDismissDisabled(model.busy)
    }
    private var progressSection: some View {
        Section(model.extracting ? "Extracting" : "Reading contents") {
            if model.extracting, let report = model.report, report.knownSize, report.total > 0 {
                let fraction = min(1, Double(model.progress.bytes) / Double(report.total))
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit())
            } else { ProgressView() }
            Text(model.progress.filename.isEmpty ? "Preparing…" : model.progress.filename).font(.caption).lineLimit(2)
            Text("\(ByteCountFormatter.string(fromByteCount: model.progress.bytes, countStyle: .file)) extracted · \(ByteCountFormatter.string(fromByteCount: model.progress.input, countStyle: .file)) read")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { model.cancel() }
        }
    }
}
