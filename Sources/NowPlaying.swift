//
//  NowPlaying.swift
//  JustHide
//
//  JustHide's own Now Playing item, for Music and Spotify.
//
//  Why it exists: while any concealment assertion is held, macOS hides its own
//  Now Playing icon -- fixed policy for every unentitled caller, measured
//  2026-09-23 -- so hiding anything costs you the player. This one lives in
//  JustHide's bundle, which the assertion always allows, so it stays.
//
//  Where the state comes from. The system-wide "now playing" information has
//  been closed to other apps since macOS 15.4, but the players announce their
//  own changes as distributed notifications, and a NAMED observer still gets
//  them with no permission at all (measured 2026-09-25: Music posts
//  com.apple.Music.playerInfo on every play, pause and skip, within a second).
//  So the item follows the notifications, and AppleScript is used only for
//  what they do not carry -- the controls, the playhead and the artwork --
//  which costs one Automation prompt per player, the first time.
//

import Cocoa

extension Notification.Name {
    /// What is playing changed, or stopped.
    static let justHideNowPlayingChanged = Notification.Name("justHideNowPlayingChanged")
}

enum Player: String, CaseIterable {
    case music
    case spotify

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    /// Music also posts the same thing as com.apple.iTunes.playerInfo; one
    /// name is enough, and listening to both would double every update.
    var notification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    /// Its AppleScript name.
    var appName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct Track: Equatable {
    let player: Player
    let name: String
    let artist: String
    let album: String
    let isPlaying: Bool
    /// Seconds, when the player said.
    let duration: TimeInterval?

    /// Both players send "Name", "Artist", "Album" and "Player State"; the
    /// length is "Total Time" from Music and "Duration" from Spotify, both in
    /// milliseconds.
    init?(player: Player, info: [AnyHashable: Any]) {
        guard let state = info["Player State"] as? String, state != "Stopped",
              let name = info["Name"] as? String else { return nil }
        self.player = player
        self.name = name
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        isPlaying = state == "Playing"
        let ms = (info["Total Time"] ?? info["Duration"]) as? NSNumber
        duration = ms.map { $0.doubleValue / 1000 }.flatMap { $0 > 0 ? $0 : nil }
    }

    init(player: Player, name: String, artist: String, album: String,
         isPlaying: Bool, duration: TimeInterval?) {
        self.player = player
        self.name = name
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
    }
}

/// Follows both players and keeps one current track.
final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()

    private(set) var current: Track?
    /// Whether the current song is a favourite, or nil where the player has
    /// no such thing that a script can reach -- Spotify's AppleScript cannot
    /// like or save a song, so its heart is simply not offered.
    private(set) var favourite: Bool?
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let distributed = DistributedNotificationCenter.default()
        for player in Player.allCases {
            observers.append(distributed.addObserver(forName: player.notification, object: nil,
                                                     queue: .main) { [weak self] note in
                self?.received(Track(player: player, info: note.userInfo ?? [:]), from: player)
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self = self, let current = self.current,
                  app?.bundleIdentifier == current.player.bundleID else { return }
            self.update(nil)
        })
        // The notifications only report CHANGES, so a song that was already
        // playing when JustHide started is asked about once. Only of a player
        // that is running: telling one that is not would launch it.
        for player in Player.allCases where player.isRunning {
            if let track = PlayerControl.currentTrack(of: player), current == nil || track.isPlaying {
                update(track)
            }
        }
    }

    func stop() {
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        isRunning = false
        current = nil
    }

    /// A player that starts playing takes over; a pause or a stop only counts
    /// from the player that is current, so pausing Spotify does not hide what
    /// Music is playing.
    private func received(_ track: Track?, from player: Player) {
        if let track = track {
            if current == nil || current?.player == player || track.isPlaying { update(track) }
        } else if current?.player == player {
            update(nil)
        }
    }

    private func update(_ track: Track?) {
        guard track != current else { return }
        let newSong = track?.name != current?.name || track?.player != current?.player
            || track?.artist != current?.artist
        current = track
        // Read once per song, not on every play and pause.
        if newSong { favourite = track.flatMap { PlayerControl.isFavourite(of: $0.player) } }
        NotificationCenter.default.post(name: .justHideNowPlayingChanged, object: nil)
    }

    /// The heart, in the bar and in the player.
    func toggleFavourite() {
        guard let player = current?.player, let favourite = favourite else { return }
        guard PlayerControl.setFavourite(!favourite, of: player) else { return }
        // Music announces nothing when a song is favourited, so the new state
        // is taken from what was just set.
        self.favourite = !favourite
        NotificationCenter.default.post(name: .justHideNowPlayingChanged, object: nil)
    }
}

/// The part that needs AppleScript, and so the Automation permission.
enum PlayerControl {
    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    /// Why the last script failed, in the user's words, or nil.
    private(set) static var lastProblem: String?

    static func send(_ command: Command, to player: Player) {
        _ = run("tell application \"\(player.appName)\" to \(command.rawValue)", player: player)
    }

    /// Seconds into the current track.
    static func position(of player: Player) -> TimeInterval? {
        run("tell application \"\(player.appName)\" to player position", player: player)?
            .doubleValue
    }

    static func currentTrack(of player: Player) -> Track? {
        let script = """
            tell application "\(player.appName)"
                if player state is stopped then return {}
                set t to current track
                return {name of t, artist of t, album of t, (player state is playing), duration of t}
            end tell
            """
        guard let list = run(script, player: player), list.numberOfItems >= 5 else { return nil }
        // Music reports duration in seconds, Spotify in milliseconds.
        let rawDuration = list.atIndex(5)?.doubleValue ?? 0
        let duration = player == .spotify ? rawDuration / 1000 : rawDuration
        return Track(player: player,
                     name: list.atIndex(1)?.stringValue ?? "",
                     artist: list.atIndex(2)?.stringValue ?? "",
                     album: list.atIndex(3)?.stringValue ?? "",
                     isPlaying: list.atIndex(4)?.booleanValue ?? false,
                     duration: duration > 0 ? duration : nil)
    }

    /// Music's heart. Its property is `favorited` on macOS 27 (`loved`, the old
    /// name, now fails with a type mismatch).
    static func isFavourite(of player: Player) -> Bool? {
        guard player == .music else { return nil }
        return run("tell application \"Music\" to get favorited of current track",
                   player: player)?.booleanValue
    }

    /// True if it took.
    static func setFavourite(_ favourite: Bool, of player: Player) -> Bool {
        guard player == .music else { return false }
        return run("tell application \"Music\" to set favorited of current track to \(favourite)",
                   player: player) != nil
    }

    /// The artwork, handed back on the main queue. Music gives the image data
    /// itself; Spotify gives a URL, fetched here.
    static func artwork(of player: Player, completion: @escaping (NSImage?) -> Void) {
        switch player {
        case .music:
            let data = run("tell application \"Music\" to get raw data of artwork 1 of current track",
                           player: player)?.data
            completion(data.flatMap(NSImage.init(data:)))
        case .spotify:
            guard let link = run("tell application \"Spotify\" to artwork url of current track",
                                 player: player)?.stringValue,
                  let url = URL(string: link) else { return completion(nil) }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { completion(image) }
            }.resume()
        }
    }

    /// Never sent to a player that is not running: an Apple event would
    /// launch it, which is not what pressing pause on a stale item means.
    private static func run(_ source: String, player: Player) -> NSAppleEventDescriptor? {
        guard player.isRunning, let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user has not allowed JustHide to control this player.
            lastProblem = code == -1743
                ? "Allow JustHide to control \(player.appName) under Privacy & Security \u{2192} Automation."
                : nil
            Log.controller.error("\(player.appName) script failed (\(code))")
            return nil
        }
        lastProblem = nil
        return result
    }
}
