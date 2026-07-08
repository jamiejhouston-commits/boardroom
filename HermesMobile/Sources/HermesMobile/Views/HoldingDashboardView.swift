import SwiftUI

/// The holding company at a glance — every division's honest numbers from the
/// relay (`GET /company/divisions`): active builds, shipped products, and the
/// live URLs a client can actually open. Until the relay upgrade lands the
/// endpoint 404s, so the screen says so plainly instead of faking rows.
struct HoldingDashboardView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController

    @State private var divisions: [DivisionInfo] = []
    @State private var loading = true
    @State private var showAdopt = false
    @State private var adoptPath = ""
    @State private var adoptNote: String?

    var body: some View {
        ZStack {
            HermesTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if divisions.isEmpty {
                        emptyState
                    } else {
                        ForEach(divisions) { division in
                            divisionCard(division)
                        }
                    }
                    adoptCard
                }
                .padding(16)
            }
        }
        .navigationTitle("Divisions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Adopt an existing app", isPresented: $showAdopt) {
            TextField("Folder on the Mac (e.g. ~/Projects/QuantFit)", text: $adoptPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Adopt") {
                Task { await adopt() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The company takes over maintenance of one of your real apps — fixes, review complaints, improvements — working inside its own repo. Nothing is ever pushed without your gate approval.")
        }
    }

    // MARK: Portfolio adoption

    private var adoptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                adoptNote = nil
                showAdopt = true
            } label: {
                Label("Adopt one of your existing apps", systemImage: "plus.rectangle.on.folder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HermesTheme.emerald)
            }
            Text("Point the company at a real app's folder on your Mac and it becomes a portfolio asset the team maintains.")
                .font(.caption)
                .foregroundStyle(HermesTheme.textSecondary)
            if let note = adoptNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
        }
        .hermesCard()
    }

    private func adopt() async {
        let path = adoptPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        do {
            try await HermesRelayClient(configuration: runtime.relayConfiguration)
                .adoptPortfolio(path: path)
            adoptNote = "Adopted — the team starts on it next heartbeat. See it in the Boardroom."
            adoptPath = ""
        } catch {
            adoptNote = error.localizedDescription
        }
        await load()
    }

    // MARK: Rows

    private func divisionCard(_ division: DivisionInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(division.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HermesTheme.textPrimary)
                Spacer()
                if !division.liveUrls.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(HermesTheme.emerald).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(HermesTheme.emerald)
                    }
                }
            }

            HStack(spacing: 10) {
                countPill("\(division.active) active", tint: HermesTheme.steel)
                countPill("\(division.shipped) shipped", tint: HermesTheme.emerald)
                // The honest P&L: what this division has cost so far (relay
                // estimate from real agent-call counts) and how often its
                // gate has bounced work — watch that number fall as the
                // lessons compound.
                if let cost = division.estCost, cost > 0 {
                    countPill(String(format: "≈$%.2f spent", cost),
                              tint: HermesTheme.textSecondary)
                }
                if let rejections = division.rejections, rejections > 0 {
                    countPill("\(rejections) gate bounces", tint: .orange)
                }
                Spacer()
            }

            ForEach(division.liveUrls, id: \.self) { live in
                if let url = URL(string: live) {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "safari")
                                .font(.caption)
                            Text(live)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2)
                        }
                        .foregroundStyle(HermesTheme.emerald)
                    }
                }
            }
        }
        .hermesCard()
    }

    private func countPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var emptyState: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking in with the divisions…")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("No division reports yet", systemImage: "building.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HermesTheme.textPrimary)
                Text("Divisions report in once the relay upgrade lands.")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        }
    }

    private func load() async {
        guard runtime.relayConfiguration.isConfigured else {
            loading = false
            return
        }
        // A relay that predates the endpoint 404s — that's the empty state,
        // not an error to shove in the owner's face.
        let fresh = try? await HermesRelayClient(configuration: runtime.relayConfiguration)
            .companyDivisions()
        if let fresh { divisions = fresh }
        loading = false
    }
}
