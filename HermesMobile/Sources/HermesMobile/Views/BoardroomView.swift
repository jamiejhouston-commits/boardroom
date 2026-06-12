import SwiftUI

/// The Chairman's room: the autonomous company at a glance.
/// Initiatives flow research → boardroom → YOUR greenlight → build →
/// Demo Day → YOUR ship call. This screen is where you decide.
struct BoardroomView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub

    @State private var thesisDraft = ""
    @State private var thesisLoaded = false
    @State private var reviseTarget: CompanyInitiative?
    @State private var reviseNote = ""

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            controlSection

            if let error = company.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !company.pendingGates.isEmpty {
                Section("Needs you") {
                    ForEach(company.pendingGates) { initiative in
                        initiativeCard(initiative)
                    }
                }
            }

            let runningInitiatives = company.state.initiatives.filter { !$0.isAwaitingDecision && !$0.isTerminal }
            if !runningInitiatives.isEmpty {
                Section("In motion") {
                    ForEach(runningInitiatives) { initiative in
                        initiativeCard(initiative)
                    }
                }
            }

            let history = company.state.initiatives.filter(\.isTerminal)
            if !history.isEmpty {
                Section("History") {
                    ForEach(history) { initiative in
                        initiativeCard(initiative)
                    }
                }
            }

            if company.state.initiatives.isEmpty {
                Section {
                    Text("No initiatives yet. Switch the company on — the Research agent scouts the market on the next heartbeat and brings the board its best idea.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Boardroom")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await company.refresh(relay: runtime.relayConfiguration) }
        .task {
            await company.refresh(relay: runtime.relayConfiguration)
            if !thesisLoaded {
                thesisDraft = company.state.thesis
                thesisLoaded = true
            }
        }
        .onReceive(ticker) { _ in
            Task { await company.refresh(relay: runtime.relayConfiguration) }
        }
        .alert("Send back with guidance", isPresented: Binding(
            get: { reviseTarget != nil },
            set: { if !$0 { reviseTarget = nil; reviseNote = "" } }
        )) {
            TextField("What should change?", text: $reviseNote)
            Button("Send back") {
                if let target = reviseTarget {
                    decide(target, .revise, note: reviseNote)
                }
                reviseTarget = nil
                reviseNote = ""
            }
            Button("Cancel", role: .cancel) { reviseTarget = nil; reviseNote = "" }
        } message: {
            Text("Your note goes straight to the team.")
        }
    }

    // MARK: Company controls

    private var controlSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { company.state.enabled },
                set: { enabled in
                    Task {
                        await company.setEnabled(enabled, thesis: thesisDraft,
                                                 relay: runtime.relayConfiguration)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Company running")
                        .font(.subheadline.weight(.semibold))
                    Text(company.state.enabled
                         ? "Heartbeat every \(company.state.config.intervalMinutes) min · quiet \(company.state.config.quietStart):00–\(company.state.config.quietEnd):00"
                         : "Halted — nothing runs, nothing spends")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(HermesTheme.emerald)

            VStack(alignment: .leading, spacing: 4) {
                Text("Investment thesis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. small consumer utilities, no crypto", text: $thesisDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .onSubmit { saveThesisIfRunning() }
                Text("The market scout filters every opportunity through this lens.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("You're the Chairman: the company scouts, debates, and builds on its own — it only waits on you at the gates.")
        }
    }

    private func saveThesisIfRunning() {
        guard company.state.enabled else { return }
        Task {
            await company.setEnabled(true, thesis: thesisDraft,
                                     relay: runtime.relayConfiguration)
        }
    }

    // MARK: Initiative card

    @ViewBuilder
    private func initiativeCard(_ initiative: CompanyInitiative) -> some View {
        NavigationLink {
            InitiativeDetailView(initiativeID: initiative.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(initiative.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    Spacer()
                    stagePill(initiative)
                }

                if !initiative.pitch.isEmpty {
                    Text(initiative.pitch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                ProgressView(value: initiative.progress)
                    .tint(initiative.stage == "killed" ? .red : HermesTheme.emerald)

                if let score = initiative.score {
                    HStack(spacing: 6) {
                        scoreChip("flame.fill", score.heat, "heat")
                        scoreChip("scope", score.fit, "fit")
                        scoreChip("hammer.fill", score.effort, "effort")
                        Spacer()
                        Text("\(initiative.callsUsed)/\(company.state.config.budgetCalls) calls")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if initiative.isAwaitingDecision && !initiative.brief.isEmpty {
                    Text(initiative.brief)
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textPrimary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HermesTheme.emerald.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if initiative.isAwaitingDecision {
                    gateButtons(initiative)
                }

                if let repoUrl = initiative.repoUrl, !repoUrl.isEmpty,
                   let url = URL(string: repoUrl) {
                    Link(destination: url) {
                        Label("Shipped → private repo", systemImage: "shippingbox.fill")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(HermesTheme.emerald)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func stagePill(_ initiative: CompanyInitiative) -> some View {
        Text(initiative.stageLabel)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(pillColor(initiative).opacity(0.15), in: Capsule())
            .foregroundStyle(pillColor(initiative))
    }

    private func pillColor(_ initiative: CompanyInitiative) -> Color {
        switch initiative.stage {
        case "gate1", "gate2": HermesTheme.gold
        case "shipped": HermesTheme.emerald
        case "killed": .red
        default: HermesTheme.textSecondary
        }
    }

    @ViewBuilder
    private func scoreChip(_ icon: String, _ value: Double?, _ label: String) -> some View {
        if let value {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text("\(label) \(Int(value))")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Gate decisions

    private func gateButtons(_ initiative: CompanyInitiative) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    decide(initiative, .approve)
                } label: {
                    Label(initiative.stage == "gate1" ? "Greenlight" : "Ship it",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HermesTheme.emerald)

                Button {
                    reviseTarget = initiative
                } label: {
                    Label("Revise", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    decide(initiative, .kill)
                } label: {
                    Label("Kill", systemImage: "xmark.circle")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)

            if initiative.stage == "gate2" {
                Button {
                    scheduleDemoDay(initiative)
                } label: {
                    Label("Add Demo Day to Calendar", systemImage: "calendar.badge.plus")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(HermesTheme.gold)
            }
        }
    }

    private func decide(_ initiative: CompanyInitiative, _ decision: CompanyDecision, note: String = "") {
        Task {
            await company.decide(id: initiative.id, decision: decision, note: note,
                                 relay: runtime.relayConfiguration)
        }
    }

    private func scheduleDemoDay(_ initiative: CompanyInitiative) {
        let date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        Task {
            await hub.schedule(topic: "Demo Day — \(initiative.title)",
                               date: date,
                               attendees: org.leadership,
                               memoSubject: nil, memoBody: nil,
                               relay: runtime.relayConfiguration)
        }
    }
}

// MARK: - Initiative detail: the full paper trail

struct InitiativeDetailView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    let initiativeID: String

    @State private var detail: CompanyInitiative?
    @State private var loadError: String?

    var body: some View {
        List {
            if let detail {
                Section("Brief") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail.title).font(.headline)
                        if !detail.pitch.isEmpty {
                            Text(detail.pitch).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !detail.brief.isEmpty {
                            Text(detail.brief).font(.subheadline)
                        }
                        if let rationale = detail.score?.rationale, !rationale.isEmpty {
                            Text(rationale).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let minutes = detail.minutes, !minutes.isEmpty {
                    Section("Minutes") {
                        ForEach(minutes) { minute in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(minute.role.uppercased())
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(HermesTheme.emerald)
                                    Spacer()
                                    Text(minute.stage)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(minute.text)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !detail.artifacts.isEmpty {
                    Section("Deliverables (on your Mac)") {
                        ForEach(detail.artifacts, id: \.self) { path in
                            Label((path as NSString).lastPathComponent, systemImage: "doc.fill")
                                .font(.caption)
                        }
                    }
                }
            } else if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(loadError, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading the paper trail…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Initiative")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        if let fresh = await company.initiativeDetail(id: initiativeID,
                                                      relay: runtime.relayConfiguration) {
            detail = fresh
        } else if detail == nil {
            loadError = "Couldn't load this initiative — check your relay connection."
        }
    }
}
