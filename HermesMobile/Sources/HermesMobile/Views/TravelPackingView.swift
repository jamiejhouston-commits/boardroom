import SwiftUI

struct TravelPackingHomeView: View {
    @EnvironmentObject private var packingStore: TravelPackingStore
    @State private var showingNewTrip = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                HermesTheme.background.ignoresSafeArea()

                Group {
                    if packingStore.trips.isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(packingStore.trips) { trip in
                                NavigationLink(value: trip.id) {
                                    TripRow(trip: trip)
                                }
                                .listRowBackground(Color.clear)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    packingStore.deleteTrip(id: packingStore.trips[index].id)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                    }
                }
                .padding(.horizontal, packingStore.trips.isEmpty ? 20 : 0)
            }
            .navigationTitle("Packing Lists")
            .navigationDestination(for: PackingTrip.ID.self) { tripID in
                TravelPackingTripDetailView(tripID: tripID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewTrip = true } label: {
                        Label("New Trip", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingNewTrip) {
                TravelPackingNewTripView { tripID in
                    path.append(tripID)
                }
                    .environmentObject(packingStore)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "suitcase.rolling.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(HermesTheme.emerald)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No trips yet. Create your first packing checklist.")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(HermesTheme.textPrimary)
                Text("Pick a ready-made list, customize it, and everything stays saved on this iPhone.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(HermesTheme.textSecondary)
            }

            Button { showingNewTrip = true } label: {
                Label("New Trip", systemImage: "plus")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HermesTheme.emerald)
            .accessibilityHint("Create a saved packing checklist")
        }
        .padding(24)
        .hermesCard()
    }
}

private struct TripRow: View {
    let trip: PackingTrip

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trip.tripType.systemImage)
                .font(.title3)
                .foregroundStyle(HermesTheme.emerald)
                .frame(width: 42, height: 42)
                .background(HermesTheme.emerald.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(trip.name)
                    .font(.headline)
                    .foregroundStyle(HermesTheme.textPrimary)
                Text(trip.tripType.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(HermesTheme.textSecondary)
            }

            Spacer()

            Text(trip.progressText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HermesTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(HermesTheme.surfaceRaised, in: Capsule())
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trip.name), \(trip.tripType.rawValue), \(trip.progressText)")
    }
}

private struct TravelPackingNewTripView: View {
    var onCreated: (PackingTrip.ID) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var packingStore: TravelPackingStore
    @State private var tripName = ""
    @State private var selectedType: PackingTripType = .weekend

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip name") {
                    TextField("Example: Seychelles weekend", text: $tripName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }

                Section("Template") {
                    ForEach(PackingTripType.allCases) { type in
                        Button {
                            selectedType = type
                        } label: {
                            HStack {
                                Label(type.rawValue, systemImage: type.systemImage)
                                Spacer()
                                if selectedType == type {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HermesTheme.emerald)
                                }
                            }
                        }
                        .foregroundStyle(HermesTheme.textPrimary)
                        .accessibilityAddTraits(selectedType == type ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Trip") {
                        if let trip = packingStore.createTrip(name: tripName, type: selectedType) {
                            dismiss()
                            onCreated(trip.id)
                        }
                    }
                    .disabled(tripName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct TravelPackingTripDetailView: View {
    @EnvironmentObject private var packingStore: TravelPackingStore
    let tripID: PackingTrip.ID

    @State private var itemTitle = ""
    @State private var editingItem: PackingChecklistItem?
    @State private var editTitle = ""

    private var trip: PackingTrip? {
        packingStore.trip(with: tripID)
    }

    var body: some View {
        ZStack {
            HermesTheme.background.ignoresSafeArea()

            if let trip {
                List {
                    Section {
                        progressHeader(for: trip)
                    }
                    .listRowBackground(Color.clear)

                    Section("Add item") {
                        HStack {
                            TextField("Something else to pack", text: $itemTitle)
                                .submitLabel(.done)
                                .onSubmit(addItem)
                            Button("Add", action: addItem)
                                .disabled(itemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Section("Checklist") {
                        if trip.items.isEmpty {
                            Text("No items yet. Add something to pack.")
                                .foregroundStyle(HermesTheme.textSecondary)
                        } else {
                            ForEach(trip.items) { item in
                                HStack(spacing: 12) {
                                    Button {
                                        packingStore.toggleItem(tripID: trip.id, itemID: item.id)
                                    } label: {
                                        Image(systemName: item.isPacked ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(item.isPacked ? HermesTheme.emerald : HermesTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.isPacked ? "Mark \(item.title) unpacked" : "Mark \(item.title) packed")

                                    Text(item.title)
                                        .font(.body)
                                        .strikethrough(item.isPacked)
                                        .foregroundStyle(item.isPacked ? HermesTheme.textSecondary : HermesTheme.textPrimary)

                                    Spacer()

                                    Button {
                                        editingItem = item
                                        editTitle = item.title
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Edit \(item.title)")
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    packingStore.deleteItem(tripID: trip.id, itemID: trip.items[index].id)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle(trip.name)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(item: $editingItem) { item in
                    editSheet(for: item, tripID: trip.id)
                }
            } else {
                ContentUnavailableView("Trip deleted", systemImage: "trash", description: Text("This packing checklist no longer exists."))
            }
        }
    }

    private func progressHeader(for trip: PackingTrip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(trip.tripType.rawValue, systemImage: trip.tripType.systemImage)
                .font(.headline)
                .foregroundStyle(HermesTheme.textPrimary)
            Text(trip.progressText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HermesTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func addItem() {
        guard let trip else { return }
        if packingStore.addItem(to: trip.id, title: itemTitle) != nil {
            itemTitle = ""
        }
    }

    private func editSheet(for item: PackingChecklistItem, tripID: PackingTrip.ID) -> some View {
        NavigationStack {
            Form {
                Section("Item title") {
                    TextField("Item", text: $editTitle)
                        .submitLabel(.done)
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingItem = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if packingStore.updateItem(tripID: tripID, itemID: item.id, title: editTitle) {
                            editingItem = nil
                        }
                    }
                    .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    TravelPackingHomeView()
        .environmentObject(TravelPackingStore(defaults: UserDefaults(suiteName: "TravelPackingPreview") ?? .standard))
}
