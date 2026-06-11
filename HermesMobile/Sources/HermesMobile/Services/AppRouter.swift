import SwiftUI

/// App-wide navigation router. Lets any screen (e.g. the Command Center)
/// switch the selected tab, so dashboard actions actually go somewhere.
@MainActor
final class AppRouter: ObservableObject {
    /// iOS shows at most 5 tabs before shoving the rest into a "More" list —
    /// so the app has exactly 5. Gateway & Settings live in the Home menu.
    enum Tab: Hashable {
        case home, chat, warRoom, agents, meetings
    }

    @Published var tab: Tab = .home

    func go(_ tab: Tab) { self.tab = tab }
}
