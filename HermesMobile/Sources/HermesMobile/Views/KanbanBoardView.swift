import SwiftUI

/// The owner's task board. Drop in a list of jobs, flip "Kanban List" on, and
/// the company works them on its own: To Do → In Progress → Done. Distinct from
/// the Boardroom pipeline (which is the company's *own* market-scouted ideas) —
/// this board is work YOU direct.
struct KanbanBoardView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController

    @State private var draft = ""
    @FocusState private var composing: Bool
    // Faster than the Boardroom's 60s tick so In Progress → Done feels live.
    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modeHeader
                composer
                board
            }
            .padding()
        }
        .background(HermesTheme.background.ignoresSafeArea())
        .navigationTitle("Task Board")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !company.tasks(in: .done).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear done") {
                        Task { await company.clearDoneTasks(relay: runtime.relayConfiguration) }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .task { await company.refresh(relay: runtime.relayConfiguration) }
        .onReceive(ticker) { _ in
            Task { await company.refresh(relay: runtime.relayConfiguration) }
        }
    }

    // MARK: Mode + status

    private var modeHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { company.taskMode },
                set: { on in
                    Task { await company.setTaskMode(on, relay: runtime.relayConfiguration) }
                }
            )) {
                Text("Kanban List").font(.subheadline.weight(.bold))
            }
            .tint(HermesTheme.gold)

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = company.errorMessage {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hermesCard()
    }

    private var statusLine: String {
        if !company.state.enabled {
            return "Company is halted — switch it on in the Boardroom so the team can work the list."
        }
        if company.taskMode {
            return "On — the team is working your list top to bottom. Their own ideas are paused until you switch this off."
        }
        return "Off — the team is pursuing their own ideas. Flip this on to make them focus on your list."
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add tasks — one per line")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Add a dark mode toggle\nWire up Firebase auth\nFix the crash on login",
                      text: $draft, axis: .vertical)
                .lineLimit(3...8)
                .font(.subheadline)
                .focused($composing)
                .padding(10)
                .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HermesTheme.hairline, lineWidth: 1))

            Button {
                let text = draft
                draft = ""
                composing = false
                Task { await company.addTasks(text, relay: runtime.relayConfiguration) }
            } label: {
                Label("Add to To Do", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HermesTheme.emerald)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .hermesCard()
    }

    // MARK: Board

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskColumn.allCases) { column in
                    columnView(column)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func columnView(_ column: TaskColumn) -> some View {
        let items = company.tasks(in: column)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: column.systemImage).font(.caption)
                Text(column.title).font(.subheadline.weight(.bold))
                Text("\(items.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(HermesTheme.hairline, in: Capsule())
                Spacer()
            }
            .foregroundStyle(columnTint(column))

            if items.isEmpty {
                Text(emptyText(column))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(items) { task in
                    taskCard(task)
                }
            }
        }
        .padding(12)
        .frame(width: 270, alignment: .topLeading)
        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(HermesTheme.hairline, lineWidth: 1))
    }

    private func taskCard(_ task: CompanyTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(HermesTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if task.column == .doing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Building…").font(.caption2.weight(.semibold)).foregroundStyle(HermesTheme.gold)
                }
            }

            if task.column == .done, let result = task.result, !result.isEmpty {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(task.failed ? .orange : .secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HermesTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            Menu {
                Button(role: .destructive) {
                    Task { await company.deleteTask(id: task.id, relay: runtime.relayConfiguration) }
                } label: {
                    Label("Remove task", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }

    private func columnTint(_ column: TaskColumn) -> Color {
        switch column {
        case .todo:  return HermesTheme.textSecondary
        case .doing: return HermesTheme.gold
        case .done:  return HermesTheme.emerald
        }
    }

    private func emptyText(_ column: TaskColumn) -> String {
        switch column {
        case .todo:  return "Nothing queued. Add tasks above."
        case .doing: return "Idle. The team pulls the next task here when Kanban List is on."
        case .done:  return "Finished tasks land here."
        }
    }
}
