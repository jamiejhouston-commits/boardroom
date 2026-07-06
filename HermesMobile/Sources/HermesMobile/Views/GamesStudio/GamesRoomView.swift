import SwiftUI

/// The Games Production Room — the Games Studio division you walk into from the
/// Boardroom HQ. A full-screen SceneKit floor with the live build on the giant
/// arcade screen, robot testers on the playtest couch, the design whiteboard, the
/// Fun Gate, the distribution board, and — the payoff — an arcade cabinet you
/// walk up to and actually play. Reads the same relay the rest of the app uses;
/// falls back to the bundled flagship so it's alive and playable offline.
struct GamesRoomView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @StateObject private var studio = GamesStudioStore()
    @Environment(\.dismiss) private var dismiss

    @State private var cameraMode: GamesCameraMode = .overview
    @State private var roamControl = RoamController(field: GamesRoomBuilder.roamField())
    @State private var sheet: RoomSheet?
    @State private var playing = false
    @State private var pitching = false

    private enum RoomSheet: String, Identifiable {
        case build, design, funGate, distribution
        var id: String { rawValue }
    }

    /// The game the cabinet plays: the first studio game whose runtime is
    /// actually bundled in the app, else the flagship (whose SkylineStack.html
    /// always ships). A relay game built to a server-side "index.html" is NOT
    /// bundled, so it must never be picked — the cabinet would load a dead
    /// "not bundled yet" placeholder instead of the real playable game.
    private var playableGame: StudioGame {
        studio.state.games.first { ArcadeGameWebView.runtimeURL($0.runtime) != nil }
            ?? StudioGame.skylineStack
    }

    var body: some View {
        ZStack {
            GamesRoomSceneView(
                game: studio.currentGame,
                bestScore: studio.localBest,
                cameraMode: cameraMode,
                roamControl: roamControl,
                onTap: handleTap
            )
            .ignoresSafeArea()

            hud
        }
        .task {
            while !Task.isCancelled {
                await studio.refresh(relay: runtime.relayConfiguration)
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .fullScreenCover(isPresented: $playing) {
            ArcadeCabinetPlayView(
                game: playableGame,
                onScore: { _, score, _ in
                    studio.recordScore(score, for: playableGame,
                                       relay: runtime.relayConfiguration)
                },
                onClose: { playing = false })
        }
        .sheet(item: $sheet) { which in
            NavigationStack { sheetContent(which) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $pitching) {
            NavigationStack {
                GamePitchSheet { title, line, pitch in
                    Task { await studio.pitch(title: title, line: line, pitch: pitch,
                                              relay: runtime.relayConfiguration) }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: Tap routing — walk up to a fixture, tap, it opens

    private func handleTap(_ tap: GamesRoomBuilder.Tap) {
        switch tap {
        case .cabinet:      playing = true
        case .megaScreen:   sheet = .build
        case .whiteboard:   sheet = .design
        case .funGate:      sheet = .funGate
        case .distribution: sheet = .distribution
        }
    }

    // MARK: HUD

    private var hud: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if cameraMode == .roam {
                HStack {
                    GamesJoystick(control: roamControl)
                    Spacer()
                    playButton
                }
                .padding(.bottom, 10)
            } else {
                HStack { Spacer(); playButton }.padding(.bottom, 10)
            }
            cameraSwitcher
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.25), value: cameraMode == .roam)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            pill(icon: "gamecontroller.fill",
                 text: studio.currentGame?.stageLabel ?? "Idle",
                 tint: GamesRoomTheme.emerald)
            if let game = studio.currentGame, game.funGate.isDecided {
                pill(icon: game.funGate.isApproved ? "checkmark.seal.fill" : "xmark.seal.fill",
                     text: "\(game.gateLabel) \(game.funGate.isApproved ? "✓" : "✗")",
                     tint: game.funGate.isApproved ? GamesRoomTheme.emerald : GamesRoomTheme.amber)
            }
            Spacer()
            Button { pitching = true } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var playButton: some View {
        Button { playing = true } label: {
            Label("Play the cabinet", systemImage: "play.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(red: 0.04, green: 0.09, blue: 0.06))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [GamesRoomTheme.emeraldHot, GamesRoomTheme.emerald],
                                   startPoint: .top, endPoint: .bottom),
                    in: Capsule())
                .shadow(color: GamesRoomTheme.emerald.opacity(0.4), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func pill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var cameraSwitcher: some View {
        HStack(spacing: 8) {
            modeButton("Overview", "square.grid.2x2", active: cameraMode == .overview) {
                cameraMode = .overview
            }
            modeButton("Orbit", "rotate.3d", active: cameraMode == .orbit) {
                cameraMode = .orbit
            }
            modeButton("Walk", "figure.walk", active: cameraMode == .roam) {
                cameraMode = .roam
            }
        }
    }

    private func modeButton(_ title: String, _ icon: String,
                            active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    if active { RoundedRectangle(cornerRadius: 12).fill(GamesRoomTheme.emerald.opacity(0.18)) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active ? GamesRoomTheme.emerald : Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ which: RoomSheet) -> some View {
        let game = studio.currentGame
        switch which {
        case .build:
            BuildSheet(game: game, isLive: studio.isLive, bestScore: studio.localBest)
        case .design:
            DesignSheet(game: game)
        case .funGate:
            FunGateSheet(game: game)
        case .distribution:
            DistributionSheet(game: game)
        }
    }
}

// MARK: - Sheets

private struct BuildSheet: View {
    let game: StudioGame?
    let isLive: Bool
    let bestScore: Int

    var body: some View {
        List {
            if let game {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.title).font(.title2.weight(.bold))
                        Text(game.lineLabel + " · " + game.stageLabel)
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: game.progress).tint(GamesRoomTheme.emerald)
                        if !game.pitch.isEmpty {
                            Text(game.pitch).font(.callout).foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }
                if let notes = game.buildNotes, !notes.isEmpty {
                    Section("Build notes") { Text(notes).font(.callout) }
                }
                if bestScore > 0 {
                    Section("Your best on the cabinet") {
                        Label("\(bestScore)", systemImage: "trophy.fill")
                            .foregroundStyle(GamesRoomTheme.gold)
                    }
                }
            } else {
                ContentUnavailableView("Studio idle", systemImage: "gamecontroller",
                                       description: Text("Pitch a game to put the studio to work."))
            }
        }
        .navigationTitle(isLive ? "Now Building" : "Studio (offline)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DesignSheet: View {
    let game: StudioGame?
    var body: some View {
        List {
            if let game {
                Section("Design pillars") {
                    if game.pillars.isEmpty { Text("—").foregroundStyle(.secondary) }
                    ForEach(game.pillars, id: \.self) { pillar in
                        Label(pillar, systemImage: "circle.fill")
                            .labelStyle(BulletLabel())
                    }
                }
                if !game.playtests.isEmpty {
                    Section("Playtests · avg \(game.averageFun, specifier: "%.1f")/10") {
                        ForEach(game.playtests) { test in
                            HStack(alignment: .top) {
                                Text(test.tester).font(.subheadline.weight(.semibold))
                                    .frame(width: 54, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("“\(test.reaction)”").font(.callout)
                                    Text("\(test.rating)/10").font(.caption)
                                        .foregroundStyle(GamesRoomTheme.gold)
                                }
                            }
                        }
                    }
                }
            } else { Text("—").foregroundStyle(.secondary) }
        }
        .navigationTitle("Design")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FunGateSheet: View {
    let game: StudioGame?
    var body: some View {
        List {
            if let gate = game?.funGate {
                Section {
                    HStack {
                        Image(systemName: gate.isApproved ? "checkmark.seal.fill"
                              : gate.isRejected ? "xmark.seal.fill" : "hourglass")
                        Text(gate.isApproved ? "Approved"
                             : gate.isRejected ? "Rejected — back to design" : "Pending")
                            .font(.headline)
                    }
                    .foregroundStyle(gate.isApproved ? GamesRoomTheme.emerald
                                     : gate.isRejected ? GamesRoomTheme.amber : Color.secondary)
                }
                if !gate.reasons.isEmpty {
                    Section(gate.isApproved ? "Why it passed" : "What has to change") {
                        ForEach(gate.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "circle.fill").labelStyle(BulletLabel())
                        }
                    }
                }
                Section {
                    Text(game?.isAssetPack == true
                         ? "The Game Designer owns the Quality Gate. A pack a real studio wouldn't pay for does not go on sale — it goes back to design."
                         : "The Game Designer owns the Fun Gate. A build that isn't fun in the first ten seconds does not ship — it goes back to design.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No verdict yet", systemImage: "hourglass")
            }
        }
        .navigationTitle(game?.gateLabel ?? "Fun Gate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DistributionSheet: View {
    let game: StudioGame?
    var body: some View {
        List {
            if let game {
                Section("Channels") {
                    ForEach(game.distributionChannels, id: \.name) { channel in
                        let status = ChannelStatus(channel.status)
                        HStack {
                            Circle()
                                .fill(status == .live ? GamesRoomTheme.emerald
                                      : status == .submitted ? GamesRoomTheme.gold : Color.gray)
                                .frame(width: 10, height: 10)
                            Text(channel.name)
                            Spacer()
                            Text(status.label).font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text(game.isAssetPack
                         ? "The distribution agent lists finished packs for sale on itch.io, the Roblox Creator Store, and engine marketplaces (Unity, Unreal/Fab, Godot)."
                         : "The distribution agent gets shipped games in front of players on itch.io, Reddit, and HTML5 portals.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else { Text("—").foregroundStyle(.secondary) }
        }
        .navigationTitle("Distribution")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GamePitchSheet: View {
    var onPitch: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var line = "hyper-casual"
    @State private var pitch = ""

    private let gameLines = [("hyper-casual", "Hyper-Casual"),
                             ("daily-puzzle", "Daily Puzzle"),
                             ("viral-funnel", "Viral Funnel")]
    // Sellable asset packs — 2D sprite/UI packs and 3D model packs built
    // store-ready for Roblox, Unity, Unreal, Godot, and the web.
    private let assetLines = [("asset-2d", "2D Asset Pack"),
                              ("asset-3d", "3D Asset Pack")]

    private var isAsset: Bool { line.hasPrefix("asset-") }

    var body: some View {
        Form {
            Section("Product") {
                TextField("Title", text: $title)
                Picker("Line", selection: $line) {
                    Section("Games") {
                        ForEach(gameLines, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Section("Asset packs — built to sell") {
                        ForEach(assetLines, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            }
            Section(isAsset ? "The pack" : "The hook") {
                TextField(isAsset ? "Theme, pieces, and who buys it"
                                  : "One line on why it's fun",
                          text: $pitch, axis: .vertical)
                    .lineLimit(2...4)
            }
            if isAsset {
                Section {
                    Text("The studio's artist builds every piece with real tools — 2D vector/sprite work and Blender-scripted 3D — exported store-ready for Roblox, Unity, Unreal, Godot, and the web, with previews, license, and import docs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pitch to the studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pitch") { onPitch(title, line, pitch); dismiss() }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(GamesRoomTheme.emerald)
                .padding(.top, 6)
            configuration.title
        }
    }
}

// MARK: - Joystick (roam mode)

/// The Games Room's left-thumb walk stick — writes straight into `RoamController`
/// (the render loop consumes it). Sibling of `HQJoystick`, bound to the generic
/// roam controller so every division room walks the same.
struct GamesJoystick: View {
    let control: RoamController
    @State private var thumb: CGSize = .zero
    private let baseSize: CGFloat = 112
    private let thumbSize: CGFloat = 48

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            Circle().fill(GamesRoomTheme.emerald.opacity(0.85))
                .frame(width: thumbSize, height: thumbSize)
                .offset(thumb).shadow(radius: 3, y: 1)
            Image(systemName: "figure.walk").font(.caption2)
                .foregroundStyle(.white.opacity(0.9)).offset(thumb)
        }
        .frame(width: baseSize, height: baseSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let radius = (baseSize - thumbSize) / 2
                    var dx = value.translation.width
                    var dy = value.translation.height
                    let len = sqrt(dx * dx + dy * dy)
                    if len > radius { dx = dx / len * radius; dy = dy / len * radius }
                    thumb = CGSize(width: dx, height: dy)
                    control.setStick(SIMD2(Float(dx / radius), Float(-dy / radius)))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { thumb = .zero }
                    control.setStick(.zero)
                }
        )
    }
}
