import SwiftUI

/// The premium HUD over the headquarters floor: a live company-pulse strip, a
/// live-meeting banner, the camera-mode switcher (now with Walk), and the
/// roam joystick. Conversation UI lives in `HQConversationOverlay`, hosted by
/// `HeadquartersView` — when it's up, the HUD's bottom controls step aside.
struct HQHud: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @Binding var cameraMode: HQCameraMode
    @Binding var selectedAgentID: String?
    let roamControl: HQRoamControl
    var controlsHidden: Bool
    var onClose: () -> Void

    private var buildingCount: Int {
        company.state.initiatives.filter { !$0.isAwaitingDecision && !$0.isTerminal }.count
    }
    private var isInspecting: Bool {
        if case .inspect = cameraMode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let meeting = company.liveMeeting {
                meetingBanner(meeting)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if !controlsHidden {
                if cameraMode == .roam {
                    HStack {
                        HQJoystick(control: roamControl)
                        Spacer()
                    }
                    .padding(.bottom, 10)
                }
                cameraSwitcher
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.25), value: controlsHidden)
        .animation(.easeInOut(duration: 0.25), value: cameraMode == .roam)
        .animation(.easeInOut(duration: 0.25), value: company.liveMeeting?.id)
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

    // MARK: Live meeting banner — the board is in session, in the room

    private func meetingBanner(_ meeting: CompanyMeeting) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.80, green: 0.26, blue: 0.24))
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color(red: 0.80, green: 0.26, blue: 0.24).opacity(0.4), lineWidth: 4))
            Text("Live: \(meeting.topic)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HermesTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(meeting.attendees.count) at the table")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(HermesTheme.hairline, lineWidth: 1))
        .padding(.top, 8)
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
            modeButton("Walk", "figure.walk", isActive: cameraMode == .roam) {
                cameraMode = .roam
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
