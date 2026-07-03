import SwiftUI

/// The cinematic AI headquarters — Slice 1. A full-screen SceneKit floor with
/// live agents under a premium HUD. Presented from the War Room; reads the same
/// `OrgStore` / `CompanyStore` the rest of the app uses.
struct HeadquartersView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss

    @State private var cameraMode: HQCameraMode = .overview
    @State private var selectedAgentID: String?

    var body: some View {
        ZStack {
            HQSceneView(
                agents: org.agents,
                companyState: company.state,
                cameraMode: cameraMode,
                onSelectAgent: { id in
                    selectedAgentID = id
                    cameraMode = .inspect(agentID: id)
                }
            )
            .ignoresSafeArea()

            HQHud(
                cameraMode: $cameraMode,
                selectedAgentID: $selectedAgentID,
                onClose: { dismiss() }
            )
        }
        .task { await company.refresh(relay: runtime.relayConfiguration) }
    }
}
