import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AgentProfileStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var router: AppRouter
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

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
    }
}
