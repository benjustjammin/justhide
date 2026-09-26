//
//  NowPlaying.swift
//  JustHide
//
//  JustHide's own Now Playing item: Music alone, or everything macOS's own
//  Now Playing shows (Settings.nowPlayingSource).
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
//  "Any app" is the system-wide information itself, read by a helper library
//  run inside Apple's own /usr/bin/perl, which MediaRemote still answers (see
//  Helper/NowPlayingHelper.m and SystemNowPlaying below). It needs no
//  permission, and it covers browsers, which announce nothing of their own.
//

import Cocoa

extension Notification.Name {
    /// What is playing changed, or stopped.
    static let justHideNowPlayingChanged = Notification.Name("justHideNowPlayingChanged")
}

enum Player: String, CaseIterable {
    // Only Music. Spotify announces itself the same way and could be added
    // here, but it was never tested, so it is not offered.
    case music

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        }
    }

    /// Music also posts the same thing as com.apple.iTunes.playerInfo; one
    /// name is enough, and listening to both would double every update.
    var notification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    /// Its AppleScript name.
    var appName: String {
        switch self {
        case .music: return "Music"
        }
    }

    init?(bundleID: String) {
        guard let player = Player.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = player
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct Track: Equatable {
    /// The app playing it: for a web page, the browser.
    let bundleID: String
    let name: String
    let artist: String
    let album: String
    let isPlaying: Bool
    /// Seconds, when the player said.
    let duration: TimeInterval?
    /// Where the playhead was, and when, for the system source, which reports
    /// it with every change; nil means ask the player (Music, by script).
    var elapsed: TimeInterval?
    var elapsedAt: Date?
    var rate: Double = 1
    /// Which picture goes with it, for the system source.
    var artworkID: String?
    /// True when it came from the system-wide source, which is then also the
    /// way to control it.
    var viaSystem = false

    /// The player JustHide knows how to script, if it is one of those.
    var player: Player? { Player(bundleID: bundleID) }

    /// The name of the app playing it, for the player and the tooltip.
    var appName: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
    }

    /// Music sends "Name", "Artist", "Album", "Player State" and "Total Time",
    /// the length in milliseconds.
    init?(player: Player, info: [AnyHashable: Any]) {
        guard let state = info["Player State"] as? String, state != "Stopped",
              let name = info["Name"] as? String else { return nil }
        bundleID = player.bundleID
        self.name = name
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        isPlaying = state == "Playing"
        let ms = info["Total Time"] as? NSNumber
        duration = ms.map { $0.doubleValue / 1000 }.flatMap { $0 > 0 ? $0 : nil }
    }

    init(player: Player, name: String, artist: String, album: String,
         isPlaying: Bool, duration: TimeInterval?) {
        bundleID = player.bundleID
        self.name = name
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
    }

    /// One "state" line from the helper.
    init?(system line: [String: Any]) {
        guard let name = line["title"] as? String, !name.isEmpty else { return nil }
        bundleID = line["bundle"] as? String ?? ""
        self.name = name
        artist = line["artist"] as? String ?? ""
        album = line["album"] as? String ?? ""
        isPlaying = (line["playing"] as? NSNumber)?.boolValue ?? false
        duration = (line["duration"] as? NSNumber)?.doubleValue
        elapsed = (line["elapsed"] as? NSNumber)?.doubleValue
        elapsedAt = (line["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        rate = (line["rate"] as? NSNumber)?.doubleValue ?? 1
        artworkID = line["artworkID"] as? String
        viaSystem = true
    }

    /// Worked out from the last report rather than asked for, so the playhead
    /// moves without a round trip every second.
    var systemPosition: TimeInterval? {
        guard let elapsed = elapsed else { return nil }
        guard isPlaying, let at = elapsedAt else { return elapsed }
        let position = elapsed + Date().timeIntervalSince(at) * (rate > 0 ? rate : 1)
        return duration.map { min(position, $0) } ?? position
    }

    /// Same song, whatever the playhead did.
    func isSameSong(as other: Track?) -> Bool {
        name == other?.name && artist == other?.artist && bundleID == other?.bundleID
    }
}

/// Keeps one current track, from Music or from the system-wide source, and
/// routes the controls to whichever one it came from.
final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()

    private(set) var current: Track?
    /// Whether the current song is a favourite, or nil where the player has
    /// no such thing that a script can reach, so the heart is not offered.
    private(set) var favourite: Bool?
    /// The source it was started for, so a change of setting restarts it.
    private var runningSource: Settings.NowPlayingSource?
    private var observers: [NSObjectProtocol] = []
    private let system = SystemNowPlaying()

    /// Why the controls or the source cannot work, in the user's words.
    var problem: String? {
        runningSource == .everything ? system.problem : PlayerControl.lastProblem
    }

    func start() {
        let source = Settings.nowPlayingSource
        guard source != runningSource else { return }
        if runningSource != nil { stop() }
        runningSource = source
        switch source {
        case .music: startMusic()
        case .everything:
            system.onChange = { [weak self] track in self?.update(track) }
            system.start()
        }
    }

    private func startMusic() {
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
                  app?.bundleIdentifier == current.bundleID else { return }
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
        system.stop()
        runningSource = nil
        current = nil
        favourite = nil
    }

    /// A player that starts playing takes over; a pause or a stop only counts
    /// from the player that is current, so pausing one player does not hide
    /// what another is playing. (One player today, but the rule costs nothing.)
    private func received(_ track: Track?, from player: Player) {
        if let track = track {
            if current == nil || current?.player == player || track.isPlaying { update(track) }
        } else if current?.player == player {
            update(nil)
        }
    }

    private func update(_ track: Track?) {
        guard track != current else { return }
        let newSong = !(track?.isSameSong(as: current) ?? (current == nil))
        current = track
        // Read once per song, not on every play and pause. Only Music has a
        // heart a script can reach, whichever source reported the song.
        if newSong { favourite = track?.player.flatMap { PlayerControl.isFavourite(of: $0) } }
        NotificationCenter.default.post(name: .justHideNowPlayingChanged, object: nil)
    }

    func send(_ command: PlayerControl.Command) {
        guard let track = current else { return }
        if track.viaSystem {
            system.send(command)
        } else if let player = track.player {
            PlayerControl.send(command, to: player)
        }
    }

    /// Seconds into the current track.
    func position() -> TimeInterval? {
        guard let track = current else { return nil }
        if track.viaSystem { return track.systemPosition }
        return track.player.flatMap { PlayerControl.position(of: $0) }
    }

    /// The current song's picture, when there is one.
    func artwork(completion: @escaping (NSImage?) -> Void) {
        guard let track = current else { return completion(nil) }
        if track.viaSystem {
            completion(system.artwork(for: track.artworkID))
        } else if let player = track.player {
            PlayerControl.artwork(of: player, completion: completion)
        } else {
            completion(nil)
        }
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

/// The system-wide Now Playing, from the helper in Contents/Frameworks run
/// inside /usr/bin/perl (see Helper/NowPlayingHelper.m for why perl). One
/// long-lived process: it reports every change as a line of JSON, and takes
/// the controls on its input. Closing that input -- including JustHide
/// quitting or crashing -- ends it, so it cannot be left behind.
final class SystemNowPlaying {
    var onChange: ((Track?) -> Void)?
    private(set) var problem: String?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var wanted = false
    /// Failures in a row; reset by any line read. Gives up after a few, so a
    /// helper macOS refuses is not relaunched forever.
    private var failures = 0
    private var artworkID: String?
    private var artworkImage: NSImage?

    private static let helperPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Frameworks/NowPlayingHelper.dylib").path
    private static let perlPath = "/usr/bin/perl"
    private static let loader = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "justhide_now_playing") or die "no entry point";
        &{DynaLoader::dl_install_xsub("main::run", $sym)};
        """

    func start() {
        wanted = true
        failures = 0
        launch()
    }

    func stop() {
        wanted = false
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
    }

    func send(_ command: PlayerControl.Command) {
        let word: String
        switch command {
        case .playPause: word = "toggle"
        case .next: word = "next"
        case .previous: word = "previous"
        }
        try? input?.write(contentsOf: Data((word + "\n").utf8))
    }

    func artwork(for id: String?) -> NSImage? {
        id != nil && id == artworkID ? artworkImage : nil
    }

    private func launch() {
        guard wanted, process == nil else { return }
        guard FileManager.default.fileExists(atPath: Self.helperPath),
              FileManager.default.isExecutableFile(atPath: Self.perlPath) else {
            fail("This Mac is missing what \u{201C}Any app\u{201D} needs; choose Music instead.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.perlPath)
        process.arguments = ["-e", Self.loader, Self.helperPath]
        let output = Pipe(), input = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Log.controller.error("Now Playing helper: \(text, privacy: .public)")
        }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.ended(ended) }
        }
        do {
            try process.run()
        } catch {
            fail("The Now Playing helper would not start (\(error.localizedDescription)).")
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        Log.controller.info("Now Playing helper started (pid \(process.processIdentifier))")
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        input = nil
        buffer.removeAll()
        guard wanted else { return }
        failures += 1
        Log.controller.error("Now Playing helper exited (\(ended.terminationStatus)), failure \(self.failures)")
        guard failures < 5 else {
            fail("macOS stopped answering JustHide\u{2019}s Now Playing helper; choose Music instead.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
    }

    private func fail(_ message: String) {
        problem = message
        Log.controller.error("\(message, privacy: .public)")
        onChange?(nil)
    }

    private func received(_ data: Data) {
        guard process != nil else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            failures = 0
            problem = nil
            switch object["type"] as? String {
            case "state":
                onChange?(Track(system: object))
            case "none":
                onChange?(nil)
            case "artwork":
                if let id = object["id"] as? String, let base64 = object["data"] as? String,
                   let bytes = Data(base64Encoded: base64), let image = NSImage(data: bytes) {
                    artworkID = id
                    artworkImage = image
                    // The picture can arrive after the song; redraw for it.
                    NotificationCenter.default.post(name: .justHideNowPlayingChanged, object: nil)
                }
            default:
                break
            }
        }
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
        // Music reports the duration here in seconds.
        let duration = list.atIndex(5)?.doubleValue ?? 0
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

    /// The artwork. Music hands over the image data itself.
    static func artwork(of player: Player, completion: @escaping (NSImage?) -> Void) {
        let data = run("tell application \"\(player.appName)\" to get raw data of artwork 1 of current track",
                       player: player)?.data
        completion(data.flatMap(NSImage.init(data:)))
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
