import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AgentProfileStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

    @State private var showLena = false
    @State private var showWelcome = true
    @State private var welcomeSession = UUID()
    @State private var hasMovedToBackground = false

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        TabView(selection: $router.tab) {
            CommandCenterView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
                .tag(AppRouter.Tab.home)

            CompanyChatView()
                .tabItem { Label("Chat", systemImage: "message.fill") }
                .tag(AppRouter.Tab.chat)

            WarRoomView()
                .tabItem { Label("War Room", systemImage: "rectangle.3.group.fill") }
                .tag(AppRouter.Tab.warRoom)

            OrgView()
                .tabItem { Label("Agents", systemImage: "person.3.fill") }
                .tag(AppRouter.Tab.agents)

            MeetingsView()
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2.fill") }
                .tag(AppRouter.Tab.meetings)
        }
        .tint(HermesTheme.emerald)
        .preferredColorScheme(appearance.colorScheme)
        .overlay(alignment: .bottomTrailing) { lenaButton }
        .overlay { welcomeOverlay }
        .sheet(isPresented: $showLena) {
            NavigationStack { AgentChatView(agent: .lena) }
        }
        .onOpenURL { url in
            if url.host == "lena" || url.absoluteString.contains("lena") { showLena = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                hasMovedToBackground = true
            } else if phase == .active, hasMovedToBackground {
                hasMovedToBackground = false
                welcomeSession = UUID()
                showWelcome = true
            }
        }
    }

    /// Lena, your assistant — always one tap away, on every tab.
    private var lenaButton: some View {
        Button { showLena = true } label: {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(colors: [Color(hex: "B66FB0"), Color(hex: "7E4E9E")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .padding(.trailing, 18)
        .padding(.bottom, 70)
        .accessibilityLabel("Call Lena, your assistant")
    }

    @ViewBuilder
    private var welcomeOverlay: some View {
        if showWelcome {
            WelcomeLaunchView(duration: 5) {
                showWelcome = false
            }
            .id(welcomeSession)
            .transition(.opacity)
            .zIndex(10)
        }
    }
}

private struct WelcomeLaunchView: View {
    var duration: TimeInterval = 5
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var isLeaving = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                Image("HermesWelcomeArtwork")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(appeared ? 1.055 : 1)
                    .offset(y: appeared ? -12 : 10)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            colors: [
                                .black.opacity(0.42),
                                .clear,
                                .black.opacity(0.2),
                                .black.opacity(0.74)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .overlay {
                        RadialGradient(
                            colors: [Color(hex: "48F2C2").opacity(0.24), .clear],
                            center: .center,
                            startRadius: 80,
                            endRadius: 360
                        )
                        .blendMode(.screen)
                        .opacity(appeared ? 1 : 0.35)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: duration), value: appeared)
            }
            .ignoresSafeArea()

            WelcomeCinematicMotion(reduceMotion: reduceMotion)
                .opacity(isLeaving ? 0.12 : 1)

            VStack(spacing: 28) {
                WelcomeStatusPill()
                    .padding(.top, 82)
                    .offset(y: appeared ? 0 : -12)
                    .opacity(appeared ? 1 : 0)

                Spacer()

                VStack(spacing: 12) {
                    Text("Boardroom")
                        .font(.system(size: 42, weight: .semibold, design: .serif))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "F6E4B4"), Color(hex: "C7A35A"), Color(hex: "FFF4CC")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("Mobile Command Intelligence")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))

                    WelcomeProgressRail(duration: duration)
                        .frame(width: 210)
                        .padding(.top, 10)

                    Text("Powered by Hermes Agent")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .padding(.top, 2)
                }
                .padding(.bottom, 62)
                .offset(y: appeared ? 0 : 20)
                .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 28)
        }
        .opacity(isLeaving ? 0 : 1)
        .scaleEffect(isLeaving ? 1.035 : 1)
        .task {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.86)) {
                appeared = true
            }

            let visibleTime = UInt64(max(duration - 0.35, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: visibleTime)

            withAnimation(.easeInOut(duration: 0.35)) {
                isLeaving = true
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
            onFinished()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes welcome screen")
    }
}

private struct WelcomeCinematicMotion: View {
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.42)
                let platform = CGPoint(x: size.width * 0.5, y: size.height * 0.63)
                let pulse = 0.65 + 0.25 * sin(time * 1.7)

                var beam = Path()
                beam.move(to: CGPoint(x: center.x - size.width * 0.09, y: 0))
                beam.addLine(to: CGPoint(x: center.x + size.width * 0.09, y: 0))
                beam.addLine(to: CGPoint(x: center.x + size.width * 0.18, y: platform.y))
                beam.addLine(to: CGPoint(x: center.x - size.width * 0.18, y: platform.y))
                beam.closeSubpath()
                context.opacity = 0.14 + pulse * 0.1
                context.fill(
                    beam,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: "FFF1B8").opacity(0.18),
                            Color(hex: "48F2C2").opacity(0.2),
                            Color(hex: "48F2C2").opacity(0.02)
                        ]),
                        startPoint: CGPoint(x: center.x, y: 0),
                        endPoint: platform
                    )
                )

                for index in 0..<4 {
                    let width = size.width * (0.46 + CGFloat(index) * 0.09)
                    let height = width * (0.19 + CGFloat(index) * 0.015)
                    let y = center.y + CGFloat(index - 1) * 20
                    let rect = CGRect(x: center.x - width / 2, y: y - height / 2, width: width, height: height)
                    let color = index.isMultiple(of: 2) ? Color(hex: "D7AF58") : Color(hex: "48F2C2")
                    context.opacity = 0.22
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: index == 0 ? 1.3 : 0.8)

                    let angle = CGFloat(time) * (0.55 + CGFloat(index) * 0.11) + CGFloat(index) * .pi / 3
                    let glint = CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
                    context.opacity = 0.74
                    context.fill(Path(ellipseIn: CGRect(x: glint.x - 2.2, y: glint.y - 2.2, width: 4.4, height: 4.4)), with: .color(color))
                }

                let sweepProgress = CGFloat(time.truncatingRemainder(dividingBy: 2.7) / 2.7)
                let sweepX = -size.width * 0.25 + sweepProgress * size.width * 1.5
                var sweep = Path()
                sweep.move(to: CGPoint(x: sweepX, y: size.height * 0.15))
                sweep.addLine(to: CGPoint(x: sweepX + 44, y: size.height * 0.12))
                sweep.addLine(to: CGPoint(x: sweepX + 180, y: size.height * 0.72))
                sweep.addLine(to: CGPoint(x: sweepX + 136, y: size.height * 0.75))
                sweep.closeSubpath()
                context.opacity = 0.18
                context.fill(
                    sweep,
                    with: .linearGradient(
                        Gradient(colors: [.clear, Color(hex: "FFF1B8").opacity(0.75), .clear]),
                        startPoint: CGPoint(x: sweepX, y: center.y),
                        endPoint: CGPoint(x: sweepX + 180, y: center.y)
                    )
                )

                for index in 0..<46 {
                    let seed = Double(index)
                    let x = (sin(seed * 17.13) * 0.5 + 0.5) * size.width
                    let drift = CGFloat(sin(time * (0.35 + seed.truncatingRemainder(dividingBy: 5) * 0.03) + seed) * 14)
                    let yBase = (cos(seed * 9.71) * 0.5 + 0.5) * size.height
                    let y = CGFloat((yBase + time * (8 + seed.truncatingRemainder(dividingBy: 18))).truncatingRemainder(dividingBy: size.height + 80)) - 40
                    let radius = CGFloat(1.2 + seed.truncatingRemainder(dividingBy: 4))
                    let color = index.isMultiple(of: 4) ? Color(hex: "D7AF58") : Color(hex: "48F2C2")
                    context.opacity = 0.22 + Double(radius) * 0.05
                    context.fill(Path(ellipseIn: CGRect(x: CGFloat(x) + drift, y: y, width: radius, height: radius)), with: .color(color))
                }
            }
            .ignoresSafeArea()
            .blendMode(.screen)
        }
    }
}

private struct WelcomeStatusPill: View {
    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color(hex: "48F2C2"))
                .frame(width: 8, height: 8)
                .shadow(color: Color(hex: "48F2C2").opacity(0.8), radius: 8)

            Text("Agent runtime online")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.34), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(hex: "48F2C2").opacity(0.26), lineWidth: 1))
        .shadow(color: Color(hex: "48F2C2").opacity(0.16), radius: 18, y: 8)
    }
}

private struct WelcomeHologram: View {
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                WelcomeRings(time: time)
                    .frame(width: 270, height: 270)
                    .offset(y: -4)

                WelcomeLightColumn(time: time)
                    .frame(width: 190, height: 300)

                WelcomeAgentConstellation(time: time)
                    .frame(width: 250, height: 250)
                    .offset(y: -6)

                WelcomeSigil(time: time)
                    .frame(width: 156, height: 156)
                    .offset(y: -2)

                WelcomeDeck(time: time)
                    .frame(width: 248, height: 72)
                    .offset(y: 118)
            }
        }
    }
}

private struct WelcomeRings: View {
    var time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let base = min(size.width, size.height)

            for index in 0..<7 {
                let phase = CGFloat(time) * (0.38 + CGFloat(index) * 0.035)
                let width = base * (0.34 + CGFloat(index) * 0.045)
                let height = width * (0.23 + CGFloat(index) * 0.018)
                var rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
                rect.origin.y += CGFloat(index - 3) * 3

                var path = Path(ellipseIn: rect)
                let color = index.isMultiple(of: 2) ? Color(hex: "45E5D0") : Color(hex: "D7AF58")
                context.opacity = 0.18 + Double(index) * 0.02
                context.stroke(path, with: .color(color), lineWidth: index == 3 ? 1.8 : 0.9)

                let markerAngle = phase + CGFloat(index) * .pi / 4
                let point = CGPoint(
                    x: center.x + cos(markerAngle) * width * 0.5,
                    y: rect.midY + sin(markerAngle) * height * 0.5
                )
                path = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                context.opacity = 0.7
                context.fill(path, with: .color(color))
            }
        }
        .blur(radius: 0.15)
    }
}

private struct WelcomeLightColumn: View {
    var time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let shimmer = 0.58 + 0.22 * sin(time * 1.7)

            let column = Path { path in
                path.move(to: CGPoint(x: center.x - 38, y: 10))
                path.addLine(to: CGPoint(x: center.x + 38, y: 10))
                path.addLine(to: CGPoint(x: center.x + 78, y: size.height - 26))
                path.addLine(to: CGPoint(x: center.x - 78, y: size.height - 26))
                path.closeSubpath()
            }

            context.opacity = shimmer
            context.fill(
                column,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(hex: "FFF1B8").opacity(0.12),
                        Color(hex: "4AF3D3").opacity(0.24),
                        Color(hex: "4AF3D3").opacity(0.03)
                    ]),
                    startPoint: CGPoint(x: center.x, y: 8),
                    endPoint: CGPoint(x: center.x, y: size.height - 18)
                )
            )

            let beam = Path { path in
                path.move(to: CGPoint(x: center.x, y: 0))
                path.addLine(to: CGPoint(x: center.x, y: size.height))
            }
            context.opacity = 0.54
            context.stroke(beam, with: .color(Color(hex: "FFF1B8")), lineWidth: 1)
        }
        .blur(radius: 0.4)
    }
}

private struct WelcomeAgentConstellation: View {
    private let nodes: [CGPoint] = [
        CGPoint(x: 0.20, y: 0.28), CGPoint(x: 0.38, y: 0.18), CGPoint(x: 0.62, y: 0.22),
        CGPoint(x: 0.80, y: 0.36), CGPoint(x: 0.71, y: 0.66), CGPoint(x: 0.47, y: 0.76),
        CGPoint(x: 0.25, y: 0.62), CGPoint(x: 0.50, y: 0.46)
    ]

    var time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let points = nodes.enumerated().map { index, node in
                CGPoint(
                    x: node.x * size.width + CGFloat(sin(time * 0.7 + Double(index))) * 5,
                    y: node.y * size.height + CGFloat(cos(time * 0.6 + Double(index) * 0.7)) * 5
                )
            }

            for index in points.indices {
                let next = points[(index + 1) % points.count]
                var line = Path()
                line.move(to: points[index])
                line.addLine(to: next)
                context.opacity = 0.2
                context.stroke(line, with: .color(Color(hex: "D7AF58")), lineWidth: 0.8)
            }

            for (index, point) in points.enumerated() {
                let pulse = 0.65 + 0.28 * sin(time * 1.2 + Double(index))
                let color = index.isMultiple(of: 3) ? Color(hex: "D7AF58") : Color(hex: "48F2C2")
                context.opacity = pulse
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
    }
}

private struct WelcomeSigil: View {
    var time: TimeInterval

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: "D7AF58").opacity(0.56), lineWidth: 1)
                .background(Circle().fill(.black.opacity(0.22)))
                .shadow(color: Color(hex: "D7AF58").opacity(0.34), radius: 28)

            Circle()
                .stroke(Color(hex: "48F2C2").opacity(0.34), lineWidth: 1)
                .scaleEffect(0.82 + 0.03 * sin(time))

            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "FFF3C2"), Color(hex: "D7AF58"), Color(hex: "49F2CE")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color(hex: "D7AF58").opacity(0.52), radius: 18)

            HStack(spacing: 18) {
                WingShape(direction: .left)
                Spacer(minLength: 42)
                WingShape(direction: .right)
            }
            .foregroundStyle(Color(hex: "F6D986").opacity(0.9))
            .frame(width: 145, height: 60)
            .offset(y: 1)
        }
    }
}

private struct WingShape: Shape {
    enum Direction { case left, right }
    var direction: Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let flip: CGFloat = direction == .left ? -1 : 1
        let origin = CGPoint(x: direction == .left ? rect.maxX : rect.minX, y: rect.midY)

        for index in 0..<5 {
            let y = CGFloat(index) * rect.height / 7
            let length = rect.width * (0.92 - CGFloat(index) * 0.12)
            path.move(to: CGPoint(x: origin.x, y: origin.y - 6 + y))
            path.addQuadCurve(
                to: CGPoint(x: origin.x + flip * length, y: origin.y - 22 + y),
                control: CGPoint(x: origin.x + flip * length * 0.45, y: origin.y - 28 + y)
            )
        }

        return path.strokedPath(.init(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }
}

private struct WelcomeDeck: View {
    var time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let top = CGRect(x: 24, y: 18, width: size.width - 48, height: 28)
            let bottom = CGRect(x: 6, y: 26, width: size.width - 12, height: 30)

            context.opacity = 0.32
            context.fill(Path(ellipseIn: bottom), with: .color(Color(hex: "48F2C2")))

            context.opacity = 0.72
            context.stroke(Path(ellipseIn: top), with: .color(Color(hex: "D7AF58")), lineWidth: 1)
            context.stroke(Path(ellipseIn: bottom), with: .color(Color(hex: "48F2C2")), lineWidth: 1)

            let sweep = time.truncatingRemainder(dividingBy: 2.6) / 2.6
            let x = 26 + CGFloat(sweep) * (size.width - 52)
            var line = Path()
            line.move(to: CGPoint(x: x, y: center.y - 18))
            line.addLine(to: CGPoint(x: x + 18, y: center.y + 18))
            context.opacity = 0.58
            context.stroke(line, with: .color(Color(hex: "FFF1B8")), lineWidth: 1.4)
        }
        .blur(radius: 0.2)
    }
}

private struct WelcomeStarfield: View {
    private let particles: [WelcomeParticle] = (0..<70).map { index in
        WelcomeParticle(
            x: Double((index * 37) % 100) / 100,
            y: Double((index * 53) % 100) / 100,
            size: Double((index % 5) + 1),
            speed: 0.12 + Double(index % 7) * 0.035
        )
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for particle in particles {
                    let particleSize = CGFloat(particle.size)
                    let y = (particle.y + time * particle.speed).truncatingRemainder(dividingBy: 1)
                    let point = CGPoint(x: particle.x * size.width, y: y * size.height)
                    let rect = CGRect(x: point.x, y: point.y, width: particleSize, height: particleSize)
                    let color = particle.size > 3 ? Color(hex: "D7AF58") : Color(hex: "48F2C2")
                    context.opacity = 0.18 + particle.size * 0.07
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct WelcomeParticle {
    var x: Double
    var y: Double
    var size: Double
    var speed: Double
}

private struct WelcomeProgressRail: View {
    var duration: TimeInterval
    @State private var fill = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "48F2C2"), Color(hex: "D7AF58")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fill ? proxy.size.width : 0)
                    .shadow(color: Color(hex: "48F2C2").opacity(0.35), radius: 10)
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.linear(duration: duration)) {
                fill = true
            }
        }
    }
}
