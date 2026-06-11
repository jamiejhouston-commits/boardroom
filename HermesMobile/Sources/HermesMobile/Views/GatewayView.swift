import SwiftUI

struct GatewayView: View {
    @EnvironmentObject private var store: AgentProfileStore
    @EnvironmentObject private var runtime: HermesRuntimeController

    private var connectors: [ConnectorSurface] {
        store.agents.first?.connectors ?? ConnectorSurface.defaults
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatusPill(title: runtime.state.title, color: runtime.state.color, systemImage: "circle.fill")
                            Spacer()
                            Text(runtime.selectedMode.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }

                        Text("Hermes Mobile should register as its own gateway client, beside Telegram, Discord, Slack, WhatsApp, Signal, Email, CLI, desktop, and dashboard.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("iPhone Surface")
                }

                Section("Mac Relay") {
                    NavigationLink {
                        MacRelaySetupView()
                    } label: {
                        HStack {
                            Label("Connect to this Mac", systemImage: "macbook.and.iphone")
                            Spacer()
                            if runtime.relayConfiguration.isConfigured {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.mint)
                            }
                        }
                    }

                    if let health = runtime.relayHealth {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(health.service)
                                .font(.headline)
                            Text("Profiles: \(health.profiles.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Messaging") {
                    ForEach(connectors) { connector in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: connector.id))
                                .foregroundStyle(connector.isConnected ? .mint : .secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(connector.name)
                                    .font(.headline)
                                Text(connector.isConnected ? "Connected" : "Not configured")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if connector.unreadCount > 0 {
                                Text("\(connector.unreadCount)")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.red, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }

                Section("Management") {
                    NavigationLink {
                        ManagementHubView()
                    } label: {
                        Label("Hermes Management", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        SkillsAndMemoryView()
                    } label: {
                        Label("Skills & Memory", systemImage: "memories")
                    }
                    NavigationLink {
                        RuntimeView()
                    } label: {
                        Label("Runtime & Sandboxes", systemImage: "cpu.fill")
                    }
                    Label("Provider keys and models", systemImage: "key.fill")
                    Label("MCP servers", systemImage: "shippingbox.fill")
                    Label("Session history", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("Gateway")
        }
    }

    private func icon(for id: String) -> String {
        switch id {
        case "telegram": "paperplane.fill"
        case "discord": "gamecontroller.fill"
        case "slack": "number"
        case "whatsapp": "phone.bubble.left.fill"
        case "signal": "lock.shield.fill"
        case "email": "envelope.fill"
        case "cli": "terminal.fill"
        default: "app.connected.to.app.below.fill"
        }
    }
}

struct MacRelaySetupView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @State private var baseURLString = ""
    @State private var token = ""
    @State private var profile = "main"
    @State private var isShowingScanner = false

    var body: some View {
        Form {
            Section {
                Button {
                    isShowingScanner = true
                } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("On the Mac, open the relay pairing page printed by the relay, then scan it here.")
            }

            Section {
                TextField("http://192.168.1.20:8787", text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                SecureField("Relay token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Profile", text: $profile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Connection")
            } footer: {
                Text("Manual fallback: run the relay on the Mac, then enter the URL and token it prints.")
            }

            Section {
                Button {
                    let configuration = HermesRelayConfiguration(
                        baseURLString: baseURLString,
                        token: token,
                        profile: profile.isEmpty ? "main" : profile,
                        deviceID: runtime.relayConfiguration.deviceID.isEmpty ? UUID().uuidString : runtime.relayConfiguration.deviceID
                    )
                    runtime.saveRelayConfiguration(configuration)
                    runtime.testRelayConnection()
                } label: {
                    Label("Save & Test", systemImage: "checkmark.circle.fill")
                }

                if runtime.relayConfiguration.isConfigured {
                    Button {
                        runtime.testRelayConnection()
                    } label: {
                        Label("Test Current Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }

            Section("Status") {
                StatusPill(title: runtime.state.title, color: runtime.state.color, systemImage: "circle.fill")
                Text(runtime.state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let health = runtime.relayHealth {
                    Text("Available profiles: \(health.profiles.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Mac Relay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            baseURLString = runtime.relayConfiguration.baseURLString
            token = runtime.relayConfiguration.token
            profile = runtime.relayConfiguration.profile
        }
        .onChange(of: runtime.relayConfiguration) { _, configuration in
            baseURLString = configuration.baseURLString
            token = configuration.token
            profile = configuration.profile
        }
        .sheet(isPresented: $isShowingScanner) {
            NavigationStack {
                PairingScannerView()
            }
        }
    }
}

struct ManagementHubView: View {
    var body: some View {
        List {
            Section("Agent Core") {
                NavigationLink {
                    SkillsAndMemoryView()
                } label: {
                    Label("Skills", systemImage: "wand.and.stars")
                }
                NavigationLink {
                    PluginsView()
                } label: {
                    Label("Plugins", systemImage: "puzzlepiece.extension.fill")
                }
                NavigationLink {
                    MCPServersView()
                } label: {
                    Label("MCP Servers", systemImage: "shippingbox.fill")
                }
                NavigationLink {
                    RuntimeView()
                } label: {
                    Label("Runtime & Sandboxes", systemImage: "cpu.fill")
                }
            }

            Section("Account & Models") {
                NavigationLink {
                    ProvidersView()
                } label: {
                    Label("Providers & Keys", systemImage: "key.fill")
                }
                Label("Model selection", systemImage: "brain.head.profile")
                Label("Nous Portal credits", systemImage: "creditcard.fill")
            }

            Section("Work Surfaces") {
                Label("Sessions", systemImage: "bubble.left.and.bubble.right.fill")
                Label("Files & artifacts", systemImage: "folder.fill")
                Label("Voice", systemImage: "waveform")
                Label("Preview rail", systemImage: "sidebar.right")
            }
        }
        .navigationTitle("Management")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SkillsAndMemoryView: View {
    @EnvironmentObject private var store: AgentProfileStore

    var body: some View {
        List {
            Section("Memory") {
                ForEach(store.agents) { agent in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.handle)
                            .font(.headline)
                        Text(agent.memorySummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Skills") {
                ForEach(Array(Set(store.agents.flatMap(\.skills))).sorted(), id: \.self) { skill in
                    Label(skill, systemImage: "sparkle.magnifyingglass")
                }
            }

            Section("Learning Loop") {
                Label("Create skills from repeated work", systemImage: "wand.and.stars")
                Label("Improve skills during use", systemImage: "arrow.triangle.2.circlepath")
                Label("Search past conversations", systemImage: "magnifyingglass")
                Label("Persist user preferences", systemImage: "person.text.rectangle.fill")
            }
        }
        .navigationTitle("Skills & Memory")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PluginsView: View {
    private let plugins = [
        ("Browser", "Web search, browser automation, screenshots, and page inspection.", true),
        ("GitHub", "Repositories, issues, pull requests, CI, and source navigation.", true),
        ("Documents", "Create, edit, render, and verify Word documents.", true),
        ("Spreadsheets", "Analyze, edit, chart, and export spreadsheet workbooks.", true),
        ("Presentations", "Build and verify PowerPoint or Google Slides-targeted decks.", true),
        ("Cloud Sandboxes", "Modal, SSH, and remote execution adapters for iOS-safe heavy work.", false)
    ]

    var body: some View {
        List {
            Section {
                ForEach(plugins, id: \.0) { plugin in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: plugin.2 ? "checkmark.seal.fill" : "icloud.and.arrow.down.fill")
                            .foregroundStyle(plugin.2 ? .mint : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.0)
                                .font(.headline)
                            Text(plugin.1)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Plugins")
            } footer: {
                Text("On iOS, plugins that need terminals, desktop control, Docker, or host filesystem access should run through a paired Hermes host or cloud sandbox.")
            }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MCPServersView: View {
    private let servers = [
        ("filesystem", "Scoped file and artifact access"),
        ("browser", "Browser actions and screenshots"),
        ("github", "Repo, issue, and PR operations"),
        ("calendar", "Availability and scheduled work"),
        ("mail", "Email search and drafting"),
        ("custom", "User-defined MCP tools")
    ]

    var body: some View {
        List {
            Section("Configured Servers") {
                ForEach(servers, id: \.0) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.0)
                            .font(.headline)
                        Text(server.1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Controls") {
                Label("Add server", systemImage: "plus.circle.fill")
                Label("Credential vault", systemImage: "lock.rectangle.stack.fill")
                Label("Tool permissions", systemImage: "checklist.checked")
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProvidersView: View {
    private let providers = [
        "Nous Portal",
        "OpenRouter",
        "OpenAI",
        "Anthropic",
        "Hugging Face",
        "NVIDIA NIM",
        "Custom endpoint"
    ]

    var body: some View {
        List {
            Section("Providers") {
                ForEach(providers, id: \.self) { provider in
                    Label(provider, systemImage: provider == "Nous Portal" ? "checkmark.circle.fill" : "circle")
                }
            }

            Section("Defaults") {
                Label("Primary model", systemImage: "brain")
                Label("Tool-use model", systemImage: "wrench.and.screwdriver.fill")
                Label("Vision model", systemImage: "eye.fill")
                Label("Text-to-speech voice", systemImage: "speaker.wave.2.fill")
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
    }
}
