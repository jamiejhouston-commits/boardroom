import SwiftUI

/// Browse the real files the team built for an initiative — the work product
/// itself, not just Demo Day screenshots. Tap a file to read it.
struct DeliverablesBrowserView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    let initiativeID: String
    let title: String

    @State private var files: [DeliverableFile] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the team's work…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else if files.isEmpty {
                Text("Nothing built yet — files appear here as the team works.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(groupedFolders, id: \.name) { folder in
                    Section(folder.name) {
                        ForEach(folder.files) { file in
                            NavigationLink {
                                DeliverableFileView(initiativeID: initiativeID, file: file)
                            } label: {
                                HStack {
                                    Image(systemName: file.isImage ? "photo" : "doc.text")
                                        .foregroundStyle(HermesTheme.emerald)
                                    Text(file.filename)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(file.sizeLabel)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private struct Folder {
        let name: String
        let files: [DeliverableFile]
    }

    /// Group by top-level directory so a real project tree reads naturally.
    private var groupedFolders: [Folder] {
        let grouped = Dictionary(grouping: files) { file -> String in
            let parts = file.path.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : "Project root"
        }
        return grouped.keys.sorted().map { Folder(name: $0, files: grouped[$0] ?? []) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            files = try await HermesRelayClient(configuration: runtime.relayConfiguration)
                .companyDeliverableFiles(id: initiativeID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One deliverable, rendered honestly: images as images, text as monospaced
/// text, anything else as a plain "can't preview" row.
struct DeliverableFileView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    let initiativeID: String
    let file: DeliverableFile

    @State private var data: Data?
    @State private var error: String?

    var body: some View {
        Group {
            if let data {
                if file.isImage, let image = UIImage(data: data) {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                } else if let text = String(data: data, encoding: .utf8) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView("No preview",
                                           systemImage: "doc.questionmark",
                                           description: Text("\(file.filename) (\(file.sizeLabel)) isn't previewable on the phone."))
                }
            } else if let error {
                ContentUnavailableView("Couldn't load the file",
                                       systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(file.filename)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                data = try await HermesRelayClient(configuration: runtime.relayConfiguration)
                    .companyDeliverableData(id: initiativeID, path: file.path)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
