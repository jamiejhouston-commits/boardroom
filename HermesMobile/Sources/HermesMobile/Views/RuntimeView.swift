import SwiftUI

struct RuntimeView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $runtime.selectedMode) {
                    ForEach(HermesRuntimeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(runtime.selectedMode.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    StatusPill(title: runtime.state.title, color: runtime.state.color, systemImage: "circle.fill")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Agent Runtime")
            }

            Section("Capabilities") {
                ForEach(runtime.capabilities) { capability in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: capability.isAvailableOnDevice ? "checkmark.circle.fill" : "network")
                            .foregroundStyle(capability.isAvailableOnDevice ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.title)
                                .font(.headline)
                            Text(capability.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .navigationTitle("Runtime")
        .navigationBarTitleDisplayMode(.inline)
    }
}
