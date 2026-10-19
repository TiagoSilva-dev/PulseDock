import AppKit
import Diagnostics
import DockRendering
import Observation
import SwiftUI
import WebKit
import WidgetCore

/// Dock Cinema: YouTube in a floating picture-in-picture player that lives above the dock.
///
/// Playback uses YouTube's official embedded player (IFrame Player API, privacy-enhanced
/// youtube-nocookie.com host) inside a WKWebView, as YouTube's terms require; PulseDock never
/// downloads or extracts streams. Nothing is contacted until the user adds a video.
///
/// What makes it PulseDock: when an agent starts waiting for you, the video pauses and the
/// player says which agent needs you; optionally it resumes once you answered.
@Observable
final class CinemaController {
    enum PlaybackState: Equatable {
        case idle, loading, playing, paused, ended
        case failed(code: Int)
    }

    private(set) var current: YouTubeVideo?
    private(set) var state: PlaybackState = .idle
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Why the video was paused automatically (for example "Claude · Approval needed").
    private(set) var pausedForAgent: String?
    private(set) var isPlayerVisible = false
    var queue: [YouTubeVideo] { data.data.cinemaQueue }
    /// The YouTube tab open in a browser (opt-in, see `BrowserVideoDetector`).
    let browser = BrowserVideoDetector()

    @ObservationIgnored private let data: WidgetDataStore
    @ObservationIgnored private let accessibility: AccessibilityOptions
    @ObservationIgnored private var window: CinemaWindow?
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: CinemaScriptBridge?
    @ObservationIgnored private var lastAttentionCount = 0
    @ObservationIgnored var themeProvider: () -> Theme = { Theme.nativeGlass }
    /// Developer reviews start videos muted (never set by the UI).
    @ObservationIgnored var startsMuted = false
    @ObservationIgnored var dockFrame: () -> CGRect? = { nil }

    init(data: WidgetDataStore, accessibility: AccessibilityOptions) {
        self.data = data
        self.accessibility = accessibility
        current = data.data.cinemaCurrent
        browser.isEnabled = { [weak data] in data?.data.cinemaBrowserDetection ?? false }
        if data.data.cinemaBrowserDetection { browser.start() }
    }

    var isPlaying: Bool { state == .playing }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }

    // MARK: Adding videos

    /// Accepts a link (watch, youtu.be, Shorts, embed…). Returns false if it is not a video.
    @discardableResult
    func add(link: String, playNow: Bool) -> Bool {
        guard var video = YouTubeLink.parse(link) else { return false }
        if let queued = queue.first(where: { $0.videoID == video.videoID }) {
            video.title = queued.title
            video.author = queued.author
        }
        if playNow || current == nil {
            play(video)
        } else if !queue.contains(where: { $0.videoID == video.videoID }) {
            data.update { $0.cinemaQueue.append(video) }
        }
        fetchMetadata(for: video)
        return true
    }

    /// Reads a YouTube link from the clipboard. Only called when the user presses "Paste".
    @discardableResult
    func pasteFromClipboard(playNow: Bool) -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string) ?? (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString else {
            return false
        }
        return add(link: text, playNow: playNow)
    }

    /// Links dropped on the tile: plain text, web URLs or `.webloc` files.
    func links(from pasteboard: NSPasteboard) -> [String] {
        var links: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls {
                if url.isFileURL, url.pathExtension == "webloc",
                   let plist = NSDictionary(contentsOf: url), let link = plist["URL"] as? String {
                    links.append(link)
                } else if !url.isFileURL {
                    links.append(url.absoluteString)
                }
            }
        }
        if let text = pasteboard.string(forType: .string) { links.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init)) }
        return links.filter { YouTubeLink.parse($0) != nil }
    }

    private func fetchMetadata(for video: YouTubeVideo) {
        guard video.title == nil else { return }
        Task { @MainActor in
            guard let metadata = await YouTubeLink.fetchMetadata(for: video) else { return }
            if current?.videoID == video.videoID {
                current?.title = metadata.title
                current?.author = metadata.author
                data.update { $0.cinemaCurrent = current }
            }
            data.update { store in
                for index in store.cinemaQueue.indices where store.cinemaQueue[index].videoID == video.videoID {
                    store.cinemaQueue[index].title = metadata.title
                    store.cinemaQueue[index].author = metadata.author
                }
            }
        }
    }

    // MARK: Browser video

    var detectsBrowserVideo: Bool {
        get { data.data.cinemaBrowserDetection }
        set {
            data.update { $0.cinemaBrowserDetection = newValue }
            if newValue {
                browser.start()
                browser.detect(userInitiated: true)
            } else {
                browser.stop()
            }
        }
    }

    /// The browser video worth suggesting: hidden when it is already in the player.
    var browserSuggestion: BrowserVideoTab? {
        guard let tab = browser.tab, tab.video.videoID != current?.videoID else { return nil }
        return tab
    }

    /// Moves the browser's video into the floating player, from the same second when the
    /// browser allows reading it (the browser's copy is paused so audio does not overlap).
    func continueFromBrowser(_ tab: BrowserVideoTab) {
        browser.handOff(tab) { [weak self] seconds in
            guard let self else { return }
            var video = tab.video
            if let seconds, seconds > 0 { video.start = seconds }
            self.play(video)
            self.browser.clear()
        }
    }

    // MARK: Playback

    func play(_ video: YouTubeVideo) {
        data.update { store in
            store.cinemaQueue.removeAll { $0.videoID == video.videoID }
            if let current = self.current, current.videoID != video.videoID, self.state != .ended {
                store.cinemaQueue.insert(current, at: 0)
            }
            store.cinemaCurrent = video
        }
        current = video
        pausedForAgent = nil
        position = Double(video.start ?? 0)
        duration = 0
        state = .loading
        showPlayer()
        load(video)
        fetchMetadata(for: video)
    }

    func togglePlayback() {
        guard current != nil else { return }
        if webView == nil {
            if let current { play(current) }
            return
        }
        pausedForAgent = nil
        evaluate(isPlaying ? "player && player.pauseVideo()" : "player && player.playVideo()")
    }

    func seek(by seconds: Double) {
        evaluate("player && player.seekTo(Math.max(0, player.getCurrentTime() + \(seconds)), true)")
    }

    func playNext() {
        guard let next = queue.first else {
            stop()
            return
        }
        play(next)
    }

    func remove(_ video: YouTubeVideo) {
        data.update { $0.cinemaQueue.removeAll { $0.videoID == video.videoID } }
    }

    func moveToTop(_ video: YouTubeVideo) {
        data.update { store in
            store.cinemaQueue.removeAll { $0.videoID == video.videoID }
            store.cinemaQueue.insert(video, at: 0)
        }
    }

    func clearQueue() {
        data.update { $0.cinemaQueue.removeAll() }
    }

    /// Closes the player (the current video stays on the tile to resume later).
    func stop() {
        evaluate("player && player.pauseVideo()")
        window?.orderOut(nil)
        tearDownWebView()
        isPlayerVisible = false
        if state != .ended { state = current == nil ? .idle : .paused }
    }

    func openOnYouTube() {
        guard let url = current?.watchURL else { return }
        stop()
        NSWorkspace.shared.open(url)
    }

    func showPlayer() {
        if window == nil { makeWindow() }
        window?.orderFrontRegardless()
        isPlayerVisible = true
    }

    func togglePlayerVisibility() {
        if isPlayerVisible, window?.isVisible == true {
            window?.orderOut(nil)
            isPlayerVisible = false
        } else if let current {
            if webView == nil { play(current) } else { showPlayer() }
        }
    }

    // MARK: Agent awareness

    var pauseForAgents: Bool {
        get { data.data.cinemaPauseForAgents }
        set { data.update { $0.cinemaPauseForAgents = newValue } }
    }

    var resumeAfterAgents: Bool {
        get { data.data.cinemaResumeAfterAgents }
        set { data.update { $0.cinemaResumeAfterAgents = newValue } }
    }

    /// Called whenever the agent summary changes. A *new* request pauses playback; answering
    /// every request resumes it when the user asked for that.
    func agentAttentionChanged(count: Int, headline: String?) {
        defer { lastAttentionCount = count }
        if count > lastAttentionCount, pauseForAgents, isPlaying {
            evaluate("player && player.pauseVideo()")
            pausedForAgent = headline ?? tr("cinema.agentNeedsYou", "An agent needs you")
            DiagnosticsRecorder.shared.record(.info, "widgets", "cinema paused for an agent request")
        } else if count == 0, let _ = pausedForAgent {
            if resumeAfterAgents {
                pausedForAgent = nil
                evaluate("player && player.playVideo()")
            }
        }
    }

    func dismissAgentPause() { pausedForAgent = nil }

    // MARK: Web player

    private func makeWindow() {
        let saved = data.data.cinemaFrame
        let size = CGSize(width: saved?[safe: 2] ?? 448, height: saved?[safe: 3] ?? 252)
        let frame: CGRect
        if let saved, saved.count == 4, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(CGRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])) }) {
            frame = CGRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
        } else {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let dock = dockFrame() ?? CGRect(x: screen.midX, y: screen.minY, width: 0, height: 80)
            frame = CGRect(x: screen.maxX - size.width - 24, y: max(screen.minY + 16, dock.maxY + 16), width: size.width, height: size.height)
        }
        let window = CinemaWindow(frame: frame, controller: self)
        window.onFrameChange = { [weak self] rect in
            self?.data.update { $0.cinemaFrame = [rect.minX, rect.minY, rect.width, rect.height] }
        }
        self.window = window
    }

    private func load(_ video: YouTubeVideo) {
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.allowsAirPlayForMediaPlayback = true
            configuration.websiteDataStore = .nonPersistent()
            let bridge = CinemaScriptBridge(controller: self)
            configuration.userContentController.add(bridge, name: "pulse")
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.underPageBackgroundColor = .black
            webView.allowsMagnification = false
            self.bridge = bridge
            self.webView = webView
            window?.install(webView: webView)
        }
        webView?.loadHTMLString(Self.playerHTML(for: video, muted: startsMuted), baseURL: Self.origin)
    }

    private func tearDownWebView() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pulse")
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        bridge = nil
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    /// The embed must be loaded from an https origin (YouTube rejects embeds without a
    /// referrer). No request is made to this host: it only names the page's origin.
    static let origin = URL(string: "https://player.pulsedock.app/")

    static func playerHTML(for video: YouTubeVideo, muted: Bool = false) -> String {
        let start = video.start ?? 0
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var player;
        function post(type, value){
          try {
            var t = player && player.getCurrentTime ? player.getCurrentTime() : 0;
            var d = player && player.getDuration ? player.getDuration() : 0;
            var data = player && player.getVideoData ? player.getVideoData() : {};
            window.webkit.messageHandlers.pulse.postMessage({type:type, value:value||0, time:t, duration:d, title:(data&&data.title)||''});
          } catch(e) {}
        }
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('p', {
            host: 'https://www.youtube-nocookie.com',
            videoId: '\(video.videoID)',
            playerVars: {autoplay:1, playsinline:1, start:\(start), rel:0, iv_load_policy:3, origin:'https://player.pulsedock.app'},
            events: {
              onReady: function(e){ if (\(muted)) { e.target.mute(); } e.target.playVideo(); post('ready'); },
              onStateChange: function(e){ post('state', e.data); },
              onError: function(e){ post('error', e.data); }
            }
          });
        }
        setInterval(function(){ if (player && player.getPlayerState && player.getPlayerState() === 1) post('tick'); }, 1000);
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }

    fileprivate func receive(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let value = (message["value"] as? NSNumber)?.intValue ?? 0
        if let time = (message["time"] as? NSNumber)?.doubleValue { position = time }
        if let total = (message["duration"] as? NSNumber)?.doubleValue, total > 0 { duration = total }
        if let title = message["title"] as? String, !title.isEmpty, current?.title == nil {
            current?.title = title
            data.update { $0.cinemaCurrent = current }
        }
        switch type {
        case "ready":
            if state == .loading { state = .paused }
        case "state":
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
            switch value {
            case 0:
                state = .ended
                if !queue.isEmpty { playNext() }
            case 1:
                state = .playing
                pausedForAgent = nil
            case 2: state = .paused
            case 3: if state != .playing { state = .loading }
            default: break
            }
        case "error":
            state = .failed(code: value)
            PulseLog.widgets.error("YouTube player error \(value, privacy: .public)")
        default:
            break
        }
    }
}

/// Receives player events from the page. Holds the controller weakly so the web view's
/// strong reference to its handlers never keeps the controller alive.
private final class CinemaScriptBridge: NSObject, WKScriptMessageHandler {
    weak var controller: CinemaController?

    init(controller: CinemaController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        controller?.receive(body)
    }
}
