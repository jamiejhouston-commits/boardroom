import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var org: OrgStore
    @State private var showPicker = false
    @State private var showSchedule = false
    @State private var active: [OrgAgent] = []
    @State private var elapsed = 32 * 60 + 47

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var roomAttendees: [OrgAgent] {
        if !active.isEmpty {
            return active
        }

        let seeded = org.leadership + org.agents.filter { $0.tier == .sub }
        return Array(seeded.prefix(13))
    }

    private var elapsedText: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                MeetingRoomSceneView(attendees: roomAttendees)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        .black.opacity(0.94),
                        .black.opacity(0.22),
                        .black.opacity(0.08),
                        .black.opacity(0.60),
                        .black.opacity(0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topChrome
                        .padding(.horizontal, 24)
                        .padding(.top, 12)

                    statusStrip
                        .padding(.horizontal, 64)
                        .padding(.top, 24)

                    Spacer()

                    NavigationLink {
                        MeetingRoomView(attendees: roomAttendees)
                    } label: {
                        meetingStatsPanel
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 62)
                    .padding(.bottom, 88)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                AttendeePickerView(confirmTitle: "Update Room") { chosen in
                    active = chosen
                }
            }
            .sheet(isPresented: $showSchedule) { ScheduleMeetingView() }
            .onReceive(ticker) { _ in elapsed += 1 }
        }
    }

    private var topChrome: some View {
        HStack {
            Button {
                showPicker = true
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.44), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            }
            .accessibilityLabel("Change attendees")

            Spacer()

            Text("Conference Room")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 8, y: 2)

            Spacer()

            HStack(spacing: 10) {
                // Schedule a meeting → Apple Calendar + 15-min alert + prep memo.
                Button { showSchedule = true } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .accessibilityLabel("Schedule meeting")

                // The internal mail room.
                NavigationLink {
                    MemosView()
                } label: {
                    Image(systemName: "envelope.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .accessibilityLabel("Memos")
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color(red: 0.0, green: 0.92, blue: 0.68))
                    .frame(width: 8, height: 8)
                    .shadow(color: .mint, radius: 8)
                Text("Meeting in Progress")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                    Text("\(roomAttendees.count) Participants")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .buttonStyle(.plain)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 17)
        .frame(height: 42)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [.cyan.opacity(0.45), .white.opacity(0.10), .cyan.opacity(0.22)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .cyan.opacity(0.14), radius: 14)
    }

    private var meetingStatsPanel: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "chart.bar.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Current Topic")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.64))
                    Text("Q2 Strategy Review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1, height: 44)

            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Time Elapsed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.64))
                    Text(elapsedText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    LinearGradient(
                        colors: [.cyan.opacity(0.52), .white.opacity(0.10), .cyan.opacity(0.25)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .shadow(color: .cyan.opacity(0.12), radius: 10)
    }
}
