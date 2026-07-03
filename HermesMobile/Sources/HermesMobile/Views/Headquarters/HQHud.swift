import SwiftUI

/// The premium HUD over the headquarters floor: a live company-pulse strip, a
/// camera-mode switcher, and a tap-to-inspect agent card with a quick Message
/// action. Glassy, minimal, non-cluttered — all `HermesTheme`.
struct HQHud: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @Binding var cameraMode: HQCameraMode
    @Binding var selectedAgentID: String?
    var onClose: () -> Void

    @State private var chatAgent: OrgAgent?

    private var buildingCount: Int {
        company.state.initiatives.filter { !$0.isAwaitingDecision && !$0.isTerminal }.count
    }
    private var selectedAgent: OrgAgent? {
        selectedAgentID.flatMap { org.agent(id: $0) }
    }
    private var isInspecting: Bool {
        if case .inspect = cameraMode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if let agent = selectedAgent {
                inspectCard(agent)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            cameraSwitcher
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.25), value: selectedAgentID)
        .sheet(item: $chatAgent) { agent in
            NavigationStack { AgentChatView(agent: agent) }
        }
    }

    // MARK: Top pulse strip

    private var topBar: some View {
        HStack(spacing: 10) {
            pulsePill(icon: "hammer.fill", text: "\(buildingCount) building", tint: HermesTheme.emerald)
            pulsePill(icon: "sparkles", text: "\(company.pendingGates.count) decisions", tint: HermesTheme.gold)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HermesTheme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private func pulsePill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(HermesTheme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    // MARK: Inspect card

    private func inspectCard(_ agent: OrgAgent) -> some View {
        let status = AgentStatusResolver.status(for: agent, in: company.state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: agent.systemImage)
                    .foregroundStyle(Color(hex: agent.accentHex))
                    .frame(width: 40, height: 40)
                    .background(Color(hex: agent.accentHex).opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.headline).foregroundStyle(HermesTheme.textPrimary)
                    Text(agent.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusChip(status)
            }
            Text(agent.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Button { chatAgent = agent } label: {
                Label("Message", systemImage: "message.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(HermesTheme.emerald, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HermesTheme.hairline, lineWidth: 1))
        .padding(.bottom, 10)
    }

    private func statusChip(_ status: HQAgentStatus) -> some View {
        HStack(spacing: 5) {
            Text(status.glyph).font(.caption2)
            Text(status.label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(status.tint).opacity(0.18), in: Capsule())
        .foregroundStyle(HermesTheme.textPrimary)
    }

    // MARK: Camera switcher

    private var cameraSwitcher: some View {
        HStack(spacing: 8) {
            modeButton("Overview", "square.grid.2x2", isActive: cameraMode == .overview) {
                selectedAgentID = nil
                cameraMode = .overview
            }
            modeButton("Orbit", "rotate.3d", isActive: cameraMode == .orbit) {
                cameraMode = .orbit
            }
            modeButton("Inspect", "viewfinder", isActive: isInspecting) {
                let id = selectedAgentID ?? HQLayout.placements(for: org.agents).first?.agent.id
                if let id {
                    selectedAgentID = id
                    cameraMode = .inspect(agentID: id)
                }
            }
        }
    }

    private func modeButton(_ title: String, _ icon: String,
                            isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(HermesTheme.textPrimary)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    if isActive {
                        RoundedRectangle(cornerRadius: 12).fill(HermesTheme.emerald.opacity(0.18))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isActive ? HermesTheme.emerald : HermesTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
