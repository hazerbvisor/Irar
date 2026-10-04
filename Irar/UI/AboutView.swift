// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Label("Irar", systemImage: "archivebox.fill").font(.title.bold())
                Text("Open your archives. Keep your files.").font(.headline)
                Text("Import RAR, RAR5 and standard ZIP archives, browse their contents, then extract and save the results to Files. Everything runs on your device.")
            }
            Section("Multipart archives") {
                Text("Import every volume together: game.part1.rar, game.part2.rar… or game.rar, game.r00, game.r01… Then open any part. Irar starts with the first volume.")
            }
            Section("Large archives") {
                Text("Import and extraction use small chunks and run away from the UI thread. Keep Irar in the foreground while working. You need space for the imported archive and its extracted files.")
            }
            Section("Supported in this version") {
                Text("Unencrypted RAR/RAR5 and standard stored/Deflate ZIP. Some archive variants and very large compression dictionaries may exceed the reader's support or iOS memory limits.")
                Text("Password-protected archives, 7z, archive creation and background extraction are not supported yet.")
            }
            Section("Open source") {
                Link("Irar source code", destination: URL(string: "https://github.com/hazerbvisor/Irar")!)
                Text("Irar is licensed under the GNU GPL. Archive reading uses libarchive 3.8.7, under its BSD and file-specific permissive licences.")
                NavigationLink("Licences") { LicenseView() }
            }
        }.navigationTitle("About")
    }
}
private struct LicenseView: View {
    @State private var texts: [String: String] = [:]
    var body: some View {
        List {
            ForEach(["GPL-3.0", "libarchive-COPYING"], id: \.self) { name in
                Section(name) { Text(texts[name] ?? "Loading…").font(.caption).textSelection(.enabled) }
            }
        }.navigationTitle("Licences")
            .task {
                for name in ["GPL-3.0", "libarchive-COPYING"] {
                    if let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Licenses") {
                        texts[name] = (try? String(contentsOf: url, encoding: .utf8)) ?? "Licence unavailable. See the source repository."
                    } else { texts[name] = "Licence unavailable. See the source repository." }
                }
            }
    }
}
