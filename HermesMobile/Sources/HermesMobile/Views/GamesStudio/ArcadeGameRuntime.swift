import SwiftUI
import WebKit

/// The playable arcade cabinet runtime. Loads the studio's bundled HTML5 game in
/// a `WKWebView` and bridges its score back to native via a `WKScriptMessageHandler`
/// named "arcade" (the game calls `window.webkit.messageHandlers.arcade.postMessage`).
///
/// This is the payoff of the whole room: walk to the cabinet, tap PLAY, and the
/// real game the studio shipped runs full-screen inside an arcade bezel.

struct ArcadeGameWebView: UIViewRepresentable {
    /// Bundled HTML filename, e.g. "SkylineStack.html". Loaded from the
    /// GamesStudio resources folder (falls back to a flat bundle lookup).
    let runtimeFile: String
    /// Called on the main actor whenever the game reports a run: (event, score, best).
    var onScore: (String, Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScore: onScore) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "arcade")
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif

        if let url = Self.runtimeURL(runtimeFile) {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.loadHTMLString(Self.missingRuntimeHTML, baseURL: nil)
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Break the retain cycle the message handler would otherwise hold.
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "arcade")
    }

    /// Resolve the bundled game file (folder-reference keeps the subdirectory).
    static func runtimeURL(_ file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension.isEmpty ? "html" : (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "GamesStudio")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static let missingRuntimeHTML = """
    <html><body style="margin:0;background:#0a0f18;color:#8b95a6;font-family:-apple-system;\
    display:flex;align-items:center;justify-content:center;height:100%;text-align:center">\
    <div>This game's runtime isn't bundled yet.</div></body></html>
    """

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onScore: (String, Int, Int) -> Void
        init(onScore: @escaping (String, Int, Int) -> Void) { self.onScore = onScore }

        nonisolated func userContentController(_ userContentController: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let event = (body["event"] as? String) ?? "gameover"
            let score = intValue(body["score"])
            let best = intValue(body["best"])
            Task { @MainActor in self.onScore(event, score, best) }
        }

        private nonisolated func intValue(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let d = any as? Double { return Int(d) }
            if let s = any as? String, let i = Int(s) { return i }
            return 0
        }
    }
}

/// The full-screen "at the cabinet" experience: an arcade bezel framing the live
/// game, a glowing marquee, and an exit button.
struct ArcadeCabinetPlayView: View {
    let game: StudioGame
    var onScore: (String, Int, Int) -> Void
    var onClose: () -> Void

    @State private var lastScore: Int?

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.05).ignoresSafeArea()

            VStack(spacing: 0) {
                marquee
                // The screen, framed by a chunky bezel.
                ArcadeGameWebView(runtimeFile: game.runtime.isEmpty ? "SkylineStack.html" : game.runtime,
                                  onScore: { event, score, best in
                    lastScore = score
                    onScore(event, score, best)
                })
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(red: 0.06, green: 0.07, blue: 0.1))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(GamesRoomTheme.emerald.opacity(0.4), lineWidth: 2))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .statusBarHidden(true)
    }

    private var marquee: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(GamesRoomTheme.gold)
            Text(game.title.uppercased())
                .font(.headline.weight(.black))
                .tracking(3)
                .foregroundStyle(
                    LinearGradient(colors: [.white, GamesRoomTheme.gold],
                                   startPoint: .top, endPoint: .bottom))
            if let lastScore {
                Text("· \(lastScore)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GamesRoomTheme.emerald)
                    .contentTransition(.numericText())
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// Small color bridge so the Games Studio SwiftUI chrome shares the room palette
/// without reaching into SceneKit's `UIColor` constants.
enum GamesRoomTheme {
    static let emerald = Color(red: 0.16, green: 0.68, blue: 0.46)
    static let emeraldHot = Color(red: 0.16, green: 0.85, blue: 0.55)
    static let gold = Color(red: 0.87, green: 0.67, blue: 0.32)
    static let amber = Color(red: 0.86, green: 0.55, blue: 0.22)
}
