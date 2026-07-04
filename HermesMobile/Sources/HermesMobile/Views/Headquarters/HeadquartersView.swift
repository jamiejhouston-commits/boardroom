import SwiftUI

/// The cinematic AI headquarters — now a LIVING one. A full-screen SceneKit
/// floor with the whole staff, walkable in first person, face-to-face agent
/// conversations (bubbles + voice), and the company's real state physically
/// in the room: war board, task kanban, event ticker, decision desk, live
/// meeting huddles. Presented from the War Room; reads the same `OrgStore` /
/// `CompanyStore` the rest of the app uses, refreshed every 15s while inside.
struct HeadquartersView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss

    @State private var cameraMode: HQCameraMode = .overview
    @State private var selectedAgentID: String?
    @State private var conversation: HQConversationModel?
    @State private var boardSheet: BoardSheet?
    @State private var fullChatAgent: OrgAgent?
    @State private var roamControl = HQRoamControl()

    private enum BoardSheet: String, Identifiable {
        case warBoard, kanban, gates
        var id: String { rawValue }

        init(_ kind: HQLiveBoards.Kind) {
            switch kind {
            case .warBoard: self = .warBoard
            case .kanban:   self = .kanban
            case .gates:    self = .gates
            }
        }
    }

    var body: some View {
        ZStack {
            HQSceneView(
                agents: org.agents,
                companyState: company.state,
                cameraMode: cameraMode,
                conversingAgentID: conversation?.agent.id,
                roamControl: roamControl,
                onSelectAgent: startConversation(with:),
                onTapBoard: { boardSheet = BoardSheet($0) }
            )
            .ignoresSafeArea()

            HQHud(
                cameraMode: $cameraMode,
                selectedAgentID: $selectedAgentID,
                roamControl: roamControl,
                controlsHidden: conversation != nil,
                onClose: {
                    conversation?.stop()
                    dismiss()
                }
            )

            if let convo = conversation {
                HQConversationOverlay(
                    model: convo,
                    status: AgentStatusResolver.status(for: convo.agent, in: company.state),
                    relay: runtime.relayConfiguration,
                    contextProvider: { CompanyContext.brief(org: org, hub: hub, company: company) },
                    onFullChat: { fullChatAgent = convo.agent },
                    onClose: endConversation
                )
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: conversation?.agent.id)
        .task {
            // The room stays LIVE while you're inside — same cadence as the
            // War Room's ticker. One-shot refresh was why it felt frozen.
            while !Task.isCancelled {
                await company.refresh(relay: runtime.relayConfiguration)
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onDisappear { conversation?.stop() }
        .sheet(item: $boardSheet) { sheet in
            NavigationStack { boardContent(sheet) }
        }
        .sheet(item: $fullChatAgent) { agent in
            NavigationStack { AgentChatView(agent: agent) }
        }
    }

    // MARK: Conversation flow — tap an agent, talk where they stand

    private func startConversation(with id: String) {
        guard let agent = org.agent(id: id) else { return }
        if conversation?.agent.id != id {
            conversation?.stop()
            conversation = HQConversationModel(agent: agent)
        }
        selectedAgentID = id
        // In roam you stay on your feet (walk & talk); otherwise glide close.
        if cameraMode != .roam {
            cameraMode = .inspect(agentID: id)
        }
    }

    private func endConversation() {
        conversation?.stop()
        conversation = nil
        selectedAgentID = nil
        if case .inspect = cameraMode { cameraMode = .overview }
    }

    // MARK: Board sheets — walk up to a wall, tap, it opens

    @ViewBuilder
    private func boardContent(_ sheet: BoardSheet) -> some View {
        switch sheet {
        case .warBoard:
            List(company.state.initiatives.reversed()) { initiative in
                NavigationLink {
                    InitiativeRoomView(initiative: initiative)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(initiative.title)
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Text(initiative.stageLabel)
                                .font(.caption)
                                .foregroundStyle(initiative.isAwaitingDecision
                                                 ? HermesTheme.gold : .secondary)
                            Spacer()
                            ProgressView(value: initiative.progress)
                                .frame(width: 90)
                                .tint(HermesTheme.emerald)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("War Board")
            .navigationBarTitleDisplayMode(.inline)

        case .kanban:
            let tasks = company.state.tasks ?? []
            List {
                ForEach([("todo", "To do"), ("doing", "Doing"), ("done", "Done")], id: \.0) { status, title in
                    let items = tasks.filter { $0.status == status }
                    Section("\(title) · \(items.count)") {
                        if items.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        }
                        ForEach(items) { task in
                            Text(task.text).font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)

        case .gates:
            HQGateSheet()
        }
    }
}

// MARK: - Decision Desk sheet — approve / revise / kill without leaving the room

private struct HQGateSheet: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss
    @State private var acting = false
    @State private var errorText: String?

    var body: some View {
        List {
            if company.pendingGates.isEmpty {
                ContentUnavailableView("No decisions waiting",
                                       systemImage: "checkmark.seal",
                                       description: Text("The desk is clear — the company keeps building."))
            }
            ForEach(company.pendingGates) { initiative in
                VStack(alignment: .leading, spacing: 10) {
                    Text(initiative.title).font(.headline)
                    Text(initiative.stageLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HermesTheme.gold)
                    Text(initiative.pitch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        gateButton("Greenlight", tint: HermesTheme.emerald) {
                            decide(initiative, .approve)
                        }
                        gateButton("Revise", tint: HermesTheme.gold) {
                            decide(initiative, .revise)
                        }
                        gateButton("Kill", tint: Color(red: 0.75, green: 0.30, blue: 0.28)) {
                            decide(initiative, .kill)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle("Decision Desk")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(acting)
        .overlay { if acting { ProgressView() } }
    }

    private func gateButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func decide(_ initiative: CompanyInitiative, _ decision: CompanyDecision) {
        acting = true
        errorText = nil
        Task {
            do {
                _ = try await HermesRelayClient(configuration: runtime.relayConfiguration)
                    .companyGate(id: initiative.id, decision: decision, note: "")
                await company.refresh(relay: runtime.relayConfiguration)
                if company.pendingGates.isEmpty { dismiss() }
            } catch {
                errorText = error.localizedDescription
            }
            acting = false
        }
    }
}
