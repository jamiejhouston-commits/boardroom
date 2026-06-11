import SwiftUI

@main
struct HermesMobileApp: App {
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
    }
}
