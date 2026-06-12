import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct HermesMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private static let companyRefreshTaskID = "com.jamiehouston.boardroom.companyRefresh"

    init() {
        // Without a delegate, iOS drops notification banners while the app
        // is foreground — gate alerts would vanish silently.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        NotificationPresenter.shared.registerCategories()
        // MUST register the BG task before launch ends — registering later
        // (in .task) silently fails and background gate alerts never fire.
        Self.registerCompanyRefresh()
    }
    @StateObject private var store = AgentProfileStore()
    @StateObject private var runtime = HermesRuntimeController()
    @StateObject private var org = OrgStore()
    @StateObject private var router = AppRouter()
    @StateObject private var meetingHub = MeetingHub()
    @StateObject private var briefings = BriefingCenter()
    @StateObject private var company = CompanyStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(runtime)
                .environmentObject(org)
                .environmentObject(router)
                .environmentObject(meetingHub)
                .environmentObject(briefings)
                .environmentObject(company)
                .task {
                    store.load()
                    runtime.boot()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Self.scheduleCompanyRefresh()
            }
        }
    }

    // MARK: Background gate alerts — "the board needs you" while the
    // phone is in your pocket. iOS decides actual timing (discretionary).

    private static var didRegisterCompanyRefresh = false

    static func registerCompanyRefresh() {
        guard !didRegisterCompanyRefresh else { return }
        didRegisterCompanyRefresh = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: companyRefreshTaskID, using: nil) { task in
            scheduleCompanyRefresh()   // keep the chain alive
            let refresh = Task {
                let relay = HermesRuntimeController.persistedRelayConfiguration()
                if relay.isConfigured,
                   let state = try? await HermesRelayClient(configuration: relay).companyState() {
                    CompanyStore.notifyNewGates(in: state)
                }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { refresh.cancel() }
        }
    }

    static func scheduleCompanyRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: companyRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
