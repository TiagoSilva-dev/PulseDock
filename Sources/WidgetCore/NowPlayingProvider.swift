import AppKit
import Diagnostics
import DockCore
import Foundation
import Observation

/// What Music or Spotify is playing.
///
/// Information comes from the distributed notifications both apps publish on every change,
/// which needs no permission. Playback controls use each app's scripting interface (Apple
/// Events), so macOS asks once for consent the first time the user presses a control.
/// No private framework (MediaRemote) is used.
@Observable
public final class NowPlayingProvider {
    public enum Player: String, Sendable, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var notificationName: String {
            switch self {
            case .music: "com.apple.Music.playerInfo"
            case .spotify: "com.spotify.client.PlaybackStateChanged"
            }
        }

        var scriptName: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            }
        }
    }

    public struct Track: Equatable, Sendable {
        public var title: String
        public var artist: String?
        public var album: String?
        public var isPlaying: Bool
        public var player: Player
    }

    public private(set) var track: Track?
    public private(set) var lastControlError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            observers.append(center.addObserver(forName: Notification.Name(player.notificationName), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let title = info["Name"] as? String
                let artist = info["Artist"] as? String
                let album = info["Album"] as? String
                let state = info["Player State"] as? String
                MainActor.assumeIsolated {
                    self?.update(player: player, title: title, artist: artist, album: album, state: state)
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let identifier = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let identifier, self?.track?.player.rawValue == identifier { self?.track = nil }
            }
        })
    }

    private func update(player: Player, title: String?, artist: String?, album: String?, state: String?) {
        if state == "Stopped" || title == nil {
            if track?.player == player { track = nil }
            return
        }
        // A paused player does not replace a playing one.
        if let current = track, current.player != player, current.isPlaying, state != "Playing" { return }
        track = Track(title: title ?? "", artist: artist, album: album, isPlaying: state == "Playing", player: player)
    }

    public var runningPlayers: [Player] {
        Player.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty }
    }

    public enum Command: String, Sendable {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    /// Sends a playback command. Only targets an app that is already running, so a control
    /// never launches Music or Spotify by surprise.
    public func send(_ command: Command, to player: Player? = nil) {
        guard let target = player ?? track?.player ?? runningPlayers.first,
              !NSRunningApplication.runningApplications(withBundleIdentifier: target.rawValue).isEmpty else { return }
        let source = "tell application id \"\(target.rawValue)\" to \(command.rawValue)"
        AppleScriptRunner.run(source) { [weak self] message in
            self?.lastControlError = message
            if let message { PulseLog.widgets.error("Playback control failed: \(message, privacy: .public)") }
        }
        if command == .playPause, var current = track, current.player == target {
            current.isPlaying.toggle()
            track = current
        }
    }
}
