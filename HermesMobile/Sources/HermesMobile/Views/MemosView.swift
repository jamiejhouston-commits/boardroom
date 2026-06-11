import SwiftUI

/// The internal mail room: scheduled meetings + memo threads with agent replies.
struct MemosView: View {
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var org: OrgStore
    @State private var showCompose = false

    var body: some View {
        List {
            if !hub.upcoming.isEmpty {
                Section("Upcoming meetings") {
                    ForEach(hub.upcoming) { meeting in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meeting.topic).font(.subheadline.weight(.semibold))
                            Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(HermesTheme.emerald)
                            Text("\(meeting.attendeeIDs.count) attendees · alert 15 min before")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) { hub.cancel(meeting) } label: {
                                Label("Cancel", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section("Memos") {
                if hub.memos.isEmpty {
                    Text("No memos yet — schedule a meeting with a prep memo, or compose one with ＋.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(hub.memos) { memo in
                    NavigationLink {
                        MemoThreadView(memoID: memo.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(memo.subject).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if hub.awaiting.contains(memo.id) {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            Text(memo.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(memo.replies.count)/\(memo.recipientIDs.count) replies · \(memo.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(HermesTheme.emerald)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { hub.deleteMemo(memo) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Memos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Compose memo")
            }
        }
        .sheet(isPresented: $showCompose) { ComposeMemoView() }
    }
}

/// One memo thread: the brief + every agent's acknowledgement.
struct MemoThreadView: View {
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var org: OrgStore
    let memoID: UUID

    private var memo: AgentMemo? { hub.memos.first { $0.id == memoID } }

    var body: some View {
        List {
            if let memo {
                Section("Brief") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memo.subject).font(.headline)
                        if let when = memo.meetingDate {
                            Label(when.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(HermesTheme.emerald)
                        }
                        Text(memo.body).font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }

                Section("Replies (\(memo.replies.count)/\(memo.recipientIDs.count))") {
                    ForEach(memo.replies) { reply in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reply.agentName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(hex: org.agent(id: reply.agentID)?.accentHex ?? "1C7A55"))
                            Text(reply.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                    if hub.awaiting.contains(memo.id) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for replies…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Memo")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Compose a standalone memo (no meeting attached).
struct ComposeMemoView: View {
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss

    @State private var subject = ""
    @State private var body_ = ""
    @State private var selected: Set<String> = []

    private var canSend: Bool {
        !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !body_.trimmingCharacters(in: .whitespaces).isEmpty
            && !selected.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Memo") {
                    TextField("Subject", text: $subject)
                    TextEditor(text: $body_)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if body_.isEmpty {
                                Text("Instructions, expectations, deliverables…")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Section("To (\(selected.count))") {
                    ForEach(org.leadership + org.agents.filter { $0.tier == .sub }) { agent in
                        Button {
                            if selected.contains(agent.id) { selected.remove(agent.id) }
                            else { selected.insert(agent.id) }
                        } label: {
                            HStack {
                                Image(systemName: agent.systemImage)
                                    .foregroundStyle(Color(hex: agent.accentHex))
                                    .frame(width: 26)
                                Text(agent.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(agent.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HermesTheme.emerald)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let recipients = org.agents.filter { selected.contains($0.id) }
                        hub.sendMemo(subject: subject, body: body_, recipients: recipients,
                                     meetingDate: nil, relay: runtime.relayConfiguration)
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
    }
}
