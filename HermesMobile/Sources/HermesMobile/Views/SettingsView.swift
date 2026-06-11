import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Choose Light or Dark, or follow your device’s system setting.")
                }

                Section("Connection") {
                    NavigationLink {
                        MacRelaySetupView()
                    } label: {
                        HStack {
                            Label("Mac Relay", systemImage: "macbook.and.iphone")
                            Spacer()
                            if runtime.relayConfiguration.isConfigured {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.mint)
                            }
                        }
                    }
                    NavigationLink {
                        RuntimeView()
                    } label: {
                        Label("Runtime & Sandboxes", systemImage: "cpu.fill")
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "Hermes Mobile")
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
