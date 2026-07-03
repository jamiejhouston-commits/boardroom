import SwiftUI

/// The money screen: what the shipped portfolio actually earns, straight
/// from RevenueCat via the relay. The same numbers are briefed to the scout
/// every cycle, so the company pitches more of what earns. When no key is
/// configured it says so honestly and explains the one-file setup.
struct RevenueDashboardView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController

    @State private var summary: RevenueSummary?
    @State private var loadError: String?

    var body: some View {
        List {
            if let summary {
                if summary.configured && !summary.metrics.isEmpty {
                    metricsSection(summary.metrics)
                    Section {
                        Label("The team sees these numbers too — the scout is briefed on portfolio performance every cycle, so new pitches double down on what earns.",
                              systemImage: "chart.line.uptrend.xyaxis")
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                } else {
                    Section("Not connected yet") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary.note?.isEmpty == false
                                 ? summary.note ?? ""
                                 : "Connect RevenueCat to see live revenue here.")
                                .font(.subheadline)
                            Text("On your Mac, create ~/.hermes/revenue-keys.json with your RevenueCat secret API key — the relay does the rest. See docs/revenue-push-demo-setup.md in the repo.")
                                .font(.caption)
                                .foregroundStyle(HermesTheme.textSecondary)
                        }
                        .padding(.vertical, 2)
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
                        Text("Fetching portfolio numbers…")
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                }
            }
        }
        .navigationTitle("Revenue")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func metricsSection(_ metrics: [RevenueMetric]) -> some View {
        Section("Portfolio") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 12) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.name)
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                            .lineLimit(2)
                        Text(metric.display)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(metric.unit == "$"
                                             ? HermesTheme.emerald
                                             : HermesTheme.textPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .padding(12)
                    .background(HermesTheme.surface,
                                in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 4)
        }
    }

    private func load() async {
        loadError = nil
        guard runtime.relayConfiguration.isConfigured else {
            loadError = "Connect your relay first (Settings → Mac Relay)."
            return
        }
        do {
            summary = try await HermesRelayClient(configuration: runtime.relayConfiguration)
                .companyRevenue()
        } catch {
            if summary == nil { loadError = error.localizedDescription }
        }
    }
}
