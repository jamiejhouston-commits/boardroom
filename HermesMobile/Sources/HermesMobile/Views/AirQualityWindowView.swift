import SwiftUI

struct AirQualityWindowHomeView: View {
    @StateObject private var store = AirQualityWindowStore()
    @State private var outdoorAQI = "35"
    @State private var indoorAQI = "60"
    @State private var safeOutdoorLimit = "50"

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Air Quality Window Alert", systemImage: "wind")
                            .font(.headline.weight(.bold))
                        Spacer()
                        if let latest = store.latest {
                            Label(latest.recommendation.rawValue, systemImage: latest.recommendation.systemImage)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(recommendationColor(latest.recommendation).opacity(0.16), in: Capsule())
                                .foregroundStyle(recommendationColor(latest.recommendation))
                        }
                    }
                    Text("Compare indoor and outdoor AQI, then get a plain window decision. Manual-first, local, and useful even without sensors or accounts.")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                    if let latest = store.latest {
                        Text(latest.summary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HermesTheme.textPrimary)
                        Text(latest.recommendation.explanation)
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Current readings") {
                TextField("Outdoor AQI", text: $outdoorAQI)
                    .keyboardType(.numberPad)
                TextField("Indoor AQI", text: $indoorAQI)
                    .keyboardType(.numberPad)
                TextField("Safe outdoor limit", text: $safeOutdoorLimit)
                    .keyboardType(.numberPad)

                Button {
                    guard let outdoor = Int(outdoorAQI),
                          let indoor = Int(indoorAQI),
                          let limit = Int(safeOutdoorLimit),
                          store.saveReading(outdoorAQI: outdoor, indoorAQI: indoor, safeOutdoorLimit: limit) != nil else { return }
                    Task { await store.notifyForLatestReading() }
                } label: {
                    Label("Save reading + alert me", systemImage: "bell.badge.fill")
                }
                .disabled(!canSave)
            }

            if !store.readings.isEmpty {
                Section("History") {
                    ForEach(store.readings) { reading in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(reading.recommendation.rawValue, systemImage: reading.recommendation.systemImage)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(recommendationColor(reading.recommendation))
                                Spacer()
                                Text(reading.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(HermesTheme.textSecondary)
                            }
                            Text(reading.summary)
                                .font(.caption)
                                .foregroundStyle(HermesTheme.textSecondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { store.deleteReading(id: store.readings[index].id) }
                    }
                }
            }
        }
        .navigationTitle("Air Quality")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset", role: .destructive) { store.reset() }
                    .disabled(store.readings.isEmpty)
            }
        }
    }

    private var canSave: Bool {
        guard let outdoor = Int(outdoorAQI),
              let indoor = Int(indoorAQI),
              let limit = Int(safeOutdoorLimit) else { return false }
        return (0...500).contains(outdoor) && (0...500).contains(indoor) && (0...500).contains(limit)
    }

    private func recommendationColor(_ recommendation: AirQualityWindowRecommendation) -> Color {
        switch recommendation {
        case .open: HermesTheme.emerald
        case .keepClosed: .orange
        case .caution: HermesTheme.gold
        }
    }
}

#Preview {
    NavigationStack { AirQualityWindowHomeView() }
}
