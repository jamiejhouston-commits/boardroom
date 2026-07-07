import SwiftUI
import UIKit

/// The Chairman's room: the autonomous company at a glance.
/// Initiatives flow research → boardroom → YOUR greenlight → build →
/// Demo Day → YOUR ship call. This screen is where you decide.
struct BoardroomView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var archive: ArchiveStore

    @State private var thesisDraft = ""
    @State private var thesisLoaded = false
    @State private var reviseTarget: CompanyInitiative?
    @State private var reviseNote = ""

    @StateObject private var pitchRecorder = VoiceNoteRecorder()
    @State private var typedPitch = ""
    @State private var pitchConfirmation: String?

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            controlSection

            pitchSection

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

            let archivedIDs = archive.archivedIDs
            let runningInitiatives = company.state.initiatives.filter {
                !$0.isAwaitingDecision && !$0.isTerminal && !archivedIDs.contains($0.id)
            }
            if !runningInitiatives.isEmpty {
                Section("In motion") {
                    ForEach(runningInitiatives) { initiative in
                        initiativeCard(initiative)
                            .swipeActions(edge: .trailing) {
                                // Only blocked items are "done" enough to archive
                                // from here — live builds keep working.
                                if initiative.stage == "blocked" {
                                    archiveButton(initiative)
                                }
                            }
                    }
                }
            }

            let history = company.state.initiatives.filter {
                $0.isTerminal && !archivedIDs.contains($0.id)
            }
            if !history.isEmpty {
                Section("History") {
                    ForEach(history) { initiative in
                        initiativeCard(initiative)
                            .swipeActions(edge: .trailing) {
                                archiveButton(initiative)
                            }
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

            Toggle(isOn: Binding(
                get: { company.taskMode },
                set: { on in
                    Task { await company.setTaskMode(on, relay: runtime.relayConfiguration) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kanban List")
                        .font(.subheadline.weight(.semibold))
                    Text(company.taskMode
                         ? "Focused on your task list — their own ideas are paused"
                         : "Off — the team pursues their own ideas")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(HermesTheme.gold)

            workingHours

            if company.taskMode && !company.state.enabled {
                Label("Switch Company running on too — nobody works the list while it's halted.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            NavigationLink {
                KanbanBoardView()
            } label: {
                HStack {
                    Label("Task board", systemImage: "checklist")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !company.tasks.isEmpty {
                        Text("\(company.tasks(in: .done).count)/\(company.tasks.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                RevenueDashboardView()
            } label: {
                Label("Revenue", systemImage: "dollarsign.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }

            NavigationLink {
                AskCompanyView()
            } label: {
                Label("Ask the company", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.subheadline.weight(.semibold))
            }

            NavigationLink {
                CronView()
            } label: {
                HStack {
                    Label("Automations", systemImage: "clock.arrow.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !company.schedules.isEmpty {
                        Text("\(company.schedules.filter(\.enabled).count) on")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                ArchiveView()
            } label: {
                HStack {
                    Label("Archive", systemImage: "archivebox.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !archive.archived.isEmpty {
                        Text("\(archive.archived.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

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

    // MARK: Pitch an idea (voice memo → initiative)

    private var pitchSection: some View {
        Section {
            Button {
                Task { await togglePitch() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: pitchRecorder.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(pitchRecorder.state == .recording ? .red : HermesTheme.emerald)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pitchRecorder.state == .recording ? "Tap to send your idea" : "Pitch an idea by voice")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HermesTheme.textPrimary)
                        Text(pitchStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pitchRecorder.state == .transcribing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(pitchRecorder.state == .transcribing)

            HStack(spacing: 8) {
                TextField("…or type an idea", text: $typedPitch, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                Button {
                    sendTypedPitch()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(HermesTheme.emerald)
                }
                .buttonStyle(.plain)
                .disabled(typedPitch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let pitchConfirmation {
                Label(pitchConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.emerald)
            }
        } header: {
            Text("Your idea")
        } footer: {
            Text("Speak (or type) an idea — the team researches it, debates it in the boardroom, and brings it back for your greenlight.")
        }
    }

    private var pitchStatus: String {
        switch pitchRecorder.state {
        case .idle:               "The board will research and debate it"
        case .recording:          "Recording… tap again when you're done"
        case .transcribing:       "Transcribing your idea…"
        case .unavailable(let m): m
        }
    }

    private func togglePitch() async {
        if pitchRecorder.state == .recording {
            if let text = await pitchRecorder.finishRecordingAndTranscribe(),
               !text.isEmpty {
                await company.submitDirective(text, relay: runtime.relayConfiguration)
                pitchConfirmation = "Sent to the board: \"\(text.prefix(60))\""
            }
        } else {
            pitchConfirmation = nil
            await pitchRecorder.beginRecording()
        }
    }

    private func sendTypedPitch() {
        let text = typedPitch
        typedPitch = ""
        Task {
            await company.submitDirective(text, relay: runtime.relayConfiguration)
            pitchConfirmation = "Sent to the board: \"\(text.prefix(60))\""
        }
    }

    // MARK: Working hours — owner sets the window (or 24/7)

    private var aroundClock: Bool {
        company.state.config.quietStart == company.state.config.quietEnd
    }

    @ViewBuilder
    private var workingHours: some View {
        Toggle(isOn: Binding(
            get: { aroundClock },
            set: { on in
                Task {
                    if on {
                        await company.setWorkingHours(quietStart: 0, quietEnd: 0,
                                                      relay: runtime.relayConfiguration)
                    } else {
                        await company.setWorkingHours(quietStart: 22, quietEnd: 7,
                                                      relay: runtime.relayConfiguration)
                    }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Work around the clock")
                    .font(.subheadline.weight(.semibold))
                Text(aroundClock ? "24/7 — no quiet hours" : "Quiet hours on — set the window below")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(HermesTheme.emerald)

        if !aroundClock {
            Picker("Pause from", selection: Binding(
                get: { company.state.config.quietStart },
                set: { value in
                    Task { await company.setWorkingHours(quietStart: value,
                                                         quietEnd: company.state.config.quietEnd,
                                                         relay: runtime.relayConfiguration) }
                }
            )) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Picker("Resume at", selection: Binding(
                get: { company.state.config.quietEnd },
                set: { value in
                    Task { await company.setWorkingHours(quietStart: company.state.config.quietStart,
                                                         quietEnd: value,
                                                         relay: runtime.relayConfiguration) }
                }
            )) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
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

    private func archiveButton(_ initiative: CompanyInitiative) -> some View {
        Button {
            archive.archive(initiative)
        } label: {
            Label("Archive", systemImage: "archivebox.fill")
        }
        .tint(HermesTheme.gold)
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
    @EnvironmentObject private var org: OrgStore
    let initiativeID: String

    @State private var detail: CompanyInitiative?
    @State private var loadError: String?
    @State private var showSchedule = false
    @State private var showMemo = false
    @State private var showIterate = false
    @State private var iterateText = ""
    @State private var demoShots: [DemoShot] = []

    struct DemoShot: Identifiable {
        let id: String        // filename, e.g. "01-home.png"
        let image: UIImage
    }

    /// The canned work order behind "Prepare App Store release" — everything
    /// the team can do without the owner's credentials, and a plain list of
    /// what still needs him (signing, App Store Connect, RevenueCat key).
    static let releaseInstruction = """
    Prepare this product for an App Store release. Do everything that doesn't \
    need the owner's credentials: fastlane setup (Fastfile, Appfile, metadata \
    folder), App Store metadata (name, subtitle, description, keywords, \
    promotional text, privacy details), versioning/build-number automation, \
    RevenueCat SDK wired in with a paywall and entitlement logic behind a \
    clean abstraction, and a RELEASE.md checklist that lists — plainly — the \
    exact steps only the owner can do (Apple signing, App Store Connect app \
    creation, uploading, RevenueCat API key). Never fake a step you can't run.
    """

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

                if !demoShots.isEmpty {
                    // Demo Day you can SEE: swipe through real screenshots the
                    // builder captured, before deciding ship or kill.
                    Section("Demo Day — see it before you ship") {
                        TabView {
                            ForEach(demoShots) { shot in
                                Image(uiImage: shot.image)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .padding(.vertical, 4)
                            }
                        }
                        .tabViewStyle(.page)
                        .indexViewStyle(.page(backgroundDisplayMode: .always))
                        .frame(height: 400)
                        .listRowBackground(Color.clear)
                    }
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

                Section("Deliverables") {
                    NavigationLink {
                        DeliverablesBrowserView(initiativeID: initiativeID,
                                                title: detail.title)
                    } label: {
                        Label("Browse the team's work", systemImage: "folder.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    if let repoUrl = detail.repoUrl, !repoUrl.isEmpty,
                       let url = URL(string: repoUrl) {
                        Link(destination: url) {
                            Label("Open the GitHub repo", systemImage: "arrow.up.forward.square")
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        InitiativeRoomView(initiative: detail)
                    } label: {
                        Label("Enter the 3D project room", systemImage: "cube.transparent")
                            .font(.subheadline.weight(.semibold))
                    }
                    if detail.stage == "shipped" {
                        // The revenue loop's on-ramp: turn a shipped repo into
                        // an App Store product. Same team, same codebase.
                        Button {
                            Task {
                                await company.iterate(id: initiativeID,
                                                      instruction: Self.releaseInstruction,
                                                      relay: runtime.relayConfiguration)
                                await load()
                            }
                        } label: {
                            Label("Prepare App Store release", systemImage: "storefront.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(HermesTheme.emerald)
                        }
                    }
                    Button {
                        showIterate = true
                    } label: {
                        Label("Request more work (next iteration)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                    }
                    Button { showSchedule = true } label: {
                        Label("Schedule a meeting about this", systemImage: "calendar.badge.plus")
                    }
                    Button { showMemo = true } label: {
                        Label("Memo the GM about next steps", systemImage: "envelope")
                    }
                } header: {
                    Text("Act on this project")
                } footer: {
                    Text("\"More work\" keeps the same team on the same codebase — add features, build the backend, set up payments, prep for the App Store. The loop reopens until you're done.")
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
        .sheet(isPresented: $showSchedule) {
            ScheduleMeetingView(prefillTopic: "Feedback: \(detail?.title ?? "")")
        }
        .sheet(isPresented: $showMemo) {
            ComposeMemoView(prefillSubject: "Next steps: \(detail?.title ?? "")",
                            prefillRecipientID: org.ceo?.id)
        }
        .alert("Request more work", isPresented: $showIterate) {
            TextField("e.g. add a backend and user accounts", text: $iterateText)
            Button("Send to the team") {
                let instruction = iterateText.trimmingCharacters(in: .whitespacesAndNewlines)
                iterateText = ""
                guard !instruction.isEmpty else { return }
                Task {
                    await company.iterate(id: initiativeID, instruction: instruction,
                                          relay: runtime.relayConfiguration)
                    await load()
                }
            }
            Button("Cancel", role: .cancel) { iterateText = "" }
        } message: {
            Text("The same team continues on the same codebase — features, backend, payments (RevenueCat), App Store prep. They'll bring it back to you at Demo Day.")
        }
    }

    private func load() async {
        loadError = nil
        if let fresh = await company.initiativeDetail(id: initiativeID,
                                                      relay: runtime.relayConfiguration) {
            detail = fresh
            await loadDemoShots(stage: fresh.stage)
        } else if detail == nil {
            loadError = "Couldn't load this initiative — check your relay connection."
        }
    }

    /// Pull the builder's Demo Day screenshots once the product is far enough
    /// along to have any. Failures just leave the gallery hidden.
    private func loadDemoShots(stage: String) async {
        guard ["demo_ready", "gate2", "shipped"].contains(stage), demoShots.isEmpty else { return }
        let client = HermesRelayClient(configuration: runtime.relayConfiguration)
        guard let files = try? await client.companyDemoFiles(id: initiativeID) else { return }
        var shots: [DemoShot] = []
        for file in files.prefix(8) where !file.hasSuffix(".mp4") {
            if let data = try? await client.companyDemoImage(id: initiativeID, filename: file),
               let image = UIImage(data: data) {
                shots.append(DemoShot(id: file, image: image))
            }
        }
        demoShots = shots
    }
}
