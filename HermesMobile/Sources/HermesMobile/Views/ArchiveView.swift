import SwiftUI

/// The Archive: finished initiatives the owner swiped away from Boardroom
/// History, auto-filed by outcome (Shipped / Killed / Blocked). Swipe an item
/// to restore it back into History.
struct ArchiveView: View {
    @EnvironmentObject private var archive: ArchiveStore

    var body: some View {
        List {
            if archive.archived.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing archived",
                        systemImage: "archivebox",
                        description: Text("Swipe a finished initiative in Boardroom → History to file it here."))
                }
            } else {
                ForEach(archive.populatedCategories) { category in
                    Section {
                        ForEach(archive.items(in: category)) { item in
                            archivedRow(item)
                        }
                    } header: {
                        Label("\(category.title) (\(archive.items(in: category).count))",
                              systemImage: category.systemImage)
                    }
                }
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func archivedRow(_ item: ArchivedInitiative) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                Spacer()
                Text(ArchiveCategory.of(stage: item.stage).title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(pillColor(item.stage).opacity(0.15), in: Capsule())
                    .foregroundStyle(pillColor(item.stage))
            }

            if !item.pitch.isEmpty {
                Text(item.pitch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let repoUrl = item.repoUrl, !repoUrl.isEmpty, let url = URL(string: repoUrl) {
                Link(destination: url) {
                    Label("Shipped → private repo", systemImage: "shippingbox.fill")
                        .font(.caption2.weight(.bold))
                }
                .tint(HermesTheme.emerald)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button {
                archive.restore(id: item.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(HermesTheme.emerald)
        }
    }

    private func pillColor(_ stage: String) -> Color {
        switch stage {
        case "shipped": HermesTheme.emerald
        case "killed":  .red
        case "blocked": .orange
        default:        HermesTheme.textSecondary
        }
    }
}
