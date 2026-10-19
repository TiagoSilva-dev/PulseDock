import Foundation

/// Browsers whose official AppleScript dictionary exposes tab URLs and titles. Firefox has no
/// such dictionary, so it cannot be detected without private APIs.
public nonisolated enum BrowserKind: String, CaseIterable, Codable, Hashable, Sendable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"
    case vivaldi = "com.vivaldi.Vivaldi"
    case arc = "company.thebrowser.Browser"

    public var bundleIdentifier: String { rawValue }

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        }
    }
}

/// A YouTube video open in a browser tab.
public nonisolated struct BrowserVideoTab: Hashable, Sendable {
    public var browser: BrowserKind
    /// 1 is the browser's front window.
    public var window: Int
    public var tab: Int
    /// The selected tab of its window.
    public var isActive: Bool
    public var video: YouTubeVideo

    public init(browser: BrowserKind, window: Int, tab: Int, isActive: Bool, video: YouTubeVideo) {
        self.browser = browser
        self.window = window
        self.tab = tab
        self.isActive = isActive
        self.video = video
    }
}

/// AppleScript sources and output parsing for browser video detection.
///
/// Privacy: the filter runs inside the script, so URLs of non-YouTube tabs never leave
/// `osascript`; titles are only read for YouTube tabs.
public nonisolated enum BrowserVideoScript {
    static let filter = #"(u contains "youtube.com/" or u contains "youtu.be/")"#

    /// Lists YouTube tabs as `window⇥tab⇥active⇥url⇥title` lines.
    public static func listSource(for browser: BrowserKind) -> String {
        let id = browser.bundleIdentifier
        switch browser {
        case .safari:
            return """
            tell application id "\(id)"
              set out to ""
              set wi to 0
              repeat with w in windows
                set wi to wi + 1
                set ct to 0
                try
                  set ct to index of current tab of w
                end try
                set ti to 0
                repeat with t in tabs of w
                  set ti to ti + 1
                  set u to URL of t
                  if u is not missing value and \(filter) then
                    set out to out & wi & tab & ti & tab & (ti = ct) & tab & u & tab & (name of t) & linefeed
                  end if
                end repeat
              end repeat
              return out
            end tell
            """
        case .arc:
            // Arc's dictionary has no tab index for the selection: only its front tab is read.
            return """
            tell application id "\(id)"
              if (count of windows) is 0 then return ""
              set t to active tab of front window
              set u to URL of t
              if \(filter) then return "1" & tab & "1" & tab & "true" & tab & u & tab & (title of t)
              return ""
            end tell
            """
        case .chrome, .brave, .edge, .vivaldi:
            return """
            tell application id "\(id)"
              set out to ""
              set wi to 0
              repeat with w in windows
                set wi to wi + 1
                set ai to active tab index of w
                set ti to 0
                repeat with t in tabs of w
                  set ti to ti + 1
                  set u to URL of t
                  if \(filter) then
                    set out to out & wi & tab & ti & tab & (ti = ai) & tab & u & tab & (title of t) & linefeed
                  end if
                end repeat
              end repeat
              return out
            end tell
            """
        }
    }

    /// Brings the tab to the front of its browser.
    public static func revealSource(for tab: BrowserVideoTab) -> String {
        let id = tab.browser.bundleIdentifier
        switch tab.browser {
        case .safari:
            return """
            tell application id "\(id)"
              set w to window \(tab.window)
              set current tab of w to tab \(tab.tab) of w
              set index of w to 1
              activate
            end tell
            """
        case .arc:
            return "tell application id \"\(id)\" to activate"
        case .chrome, .brave, .edge, .vivaldi:
            return """
            tell application id "\(id)"
              set w to window \(tab.window)
              set active tab index of w to \(tab.tab)
              set index of w to 1
              activate
            end tell
            """
        }
    }

    /// Reads the playback position and pauses the page's video, so the floating player can
    /// continue from the same second. Browsers only run it when the user enabled "Allow
    /// JavaScript from Apple Events"; otherwise it fails and the URL's start time is used.
    public static func handOffSource(for tab: BrowserVideoTab) -> String? {
        let script = "(function(){var v=document.querySelector('video');if(!v)return '';v.pause();return String(Math.floor(v.currentTime));})()"
        let id = tab.browser.bundleIdentifier
        switch tab.browser {
        case .safari:
            return "tell application id \"\(id)\" to do JavaScript \"\(script)\" in tab \(tab.tab) of window \(tab.window)"
        case .chrome, .brave, .edge, .vivaldi:
            return "tell application id \"\(id)\" to execute tab \(tab.tab) of window \(tab.window) javascript \"\(script)\""
        case .arc:
            return nil
        }
    }

    public static func parse(_ output: String, browser: BrowserKind) -> [BrowserVideoTab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let window = Int(fields[0]), let tab = Int(fields[1]),
                  var video = YouTubeLink.parse(fields[3]) else { return nil }
            if fields.count == 5 { video.title = cleanTitle(fields[4]) }
            return BrowserVideoTab(browser: browser, window: window, tab: tab, isActive: fields[2] == "true", video: video)
        }
    }

    /// "(3) Song name - YouTube" → "Song name".
    static func cleanTitle(_ title: String) -> String? {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube Music", " - YouTube"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"), text[text.index(after: text.startIndex)..<close].allSatisfy(\.isNumber) {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, text != "YouTube" else { return nil }
        return String(text.prefix(200))
    }

    /// The tab the user is most likely watching: the selected tab of the front window of the
    /// most recently used browser, then other selected tabs, then background tabs.
    public static func best(_ tabs: [BrowserVideoTab], recency: [BrowserKind]) -> BrowserVideoTab? {
        func rank(_ tab: BrowserVideoTab) -> (Int, Int, Int, Int) {
            let browserRank = recency.firstIndex(of: tab.browser) ?? recency.count
            return (tab.isActive ? 0 : 1, browserRank, tab.window, tab.tab)
        }
        return tabs.min { rank($0) < rank($1) }
    }
}
