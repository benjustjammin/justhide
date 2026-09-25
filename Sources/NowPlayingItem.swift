//
//  NowPlayingItem.swift
//  JustHide
//
//  The Now Playing item in the bar and the small player it opens.
//
//  Placement: the item keeps ONE autosave name for life, so when it goes and
//  comes back ("only while playing") macOS returns it to the slot it
//  remembers for that name. Items of ours that took a NEW name each time are
//  what used to land somewhere new and shuffle everyone else's icons.
//
//  Icons rather than arrows where it can be helped: a second display draws our
//  images mirrored (see JustHide.applyGlyph), and a play triangle mirrored
//  points backwards. The waveform and the pause bars read the same either way.
//

import Cocoa

final class NowPlayingItem: NSObject {
    static let shared = NowPlayingItem()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var player: PlayerViewController?

    /// Called whenever the item may need to change. Posts
    /// justHideOwnItemsChanged when it did change, because a secondary display
    /// freezes our items while an assertion is held and only a fresh assertion
    /// redraws them there.
    func apply() {
        guard Settings.showsNowPlaying else {
            NowPlayingMonitor.shared.stop()
            remove()
            return
        }
        NowPlayingMonitor.shared.start()
        let track = NowPlayingMonitor.shared.current
        guard track != nil || Settings.nowPlayingAppearance == .always || popover.isShown else {
            remove()
            return
        }
        let item = self.item ?? create()
        draw(item, track: track)
        player?.show(track)
        NotificationCenter.default.post(name: .justHideOwnItemsChanged, object: nil)
    }

    private func create() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "nowplaying"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        self.item = item
        return item
    }

    private func remove() {
        guard let item = item else { return }
        popover.performClose(nil)
        strip?.stop()
        strip?.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        NotificationCenter.default.post(name: .justHideOwnItemsChanged, object: nil)
    }

    private var strip: TitleStrip?

    private func draw(_ item: NSStatusItem, track: Track?) {
        guard let button = item.button else { return }
        // Paused is the pause bars in a circle: bare, they are much narrower
        // than the waveform, and the icon visibly changed size on every pause.
        let symbol = track == nil ? "music.note" : (track!.isPlaying ? "waveform" : "pause.circle")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true

        if Settings.nowPlayingStyle == .title, let track = track {
            button.image = nil
            button.title = ""
            let strip = self.strip ?? TitleStrip()
            if strip.superview !== button {
                strip.frame = button.bounds
                strip.autoresizingMask = [.width, .height]
                button.addSubview(strip)
            }
            self.strip = strip
            let text = track.artist.isEmpty ? track.name : "\(track.name) \u{2013} \(track.artist)"
            item.length = strip.show(icon: image, text: text,
                                     favourite: NowPlayingMonitor.shared.favourite,
                                     scrolling: track.isPlaying)
        } else {
            strip?.removeFromSuperview()
            strip?.stop()
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
            // A fixed width, so switching between the symbols moves nothing.
            item.length = 28
        }
        button.setAccessibilityLabel(track.map { "Now Playing: \($0.name), \($0.artist)" }
                                     ?? "Now Playing: nothing")
        button.toolTip = track.map { "\($0.name)\n\($0.artist)" }
    }

    @objc private func clicked() {
        guard let button = item?.button else { return }
        // A click on the heart favourites; anywhere else opens the player.
        // Judged in SCREEN coordinates against the item's own window frame: on
        // macOS 27 an event's locationInWindow does not map onto the button
        // (the first version compared that and never hit the heart), while
        // the window frame is exactly where the item is drawn.
        if let strip = strip, strip.superview != nil, NowPlayingMonitor.shared.favourite != nil,
           let frame = button.window?.frame,
           NSEvent.mouseLocation.x > frame.maxX - TitleStrip.heartZone {
            NowPlayingMonitor.shared.toggleFavourite()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let player = self.player ?? PlayerViewController()
        self.player = player
        popover.contentViewController = player
        popover.behavior = .transient
        player.show(NowPlayingMonitor.shared.current)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        player.startTicking()
    }
}

extension Notification.Name {
    /// One of JustHide's own menu bar items appeared, went, or was redrawn.
    static let justHideOwnItemsChanged = Notification.Name("justHideOwnItemsChanged")
}

/// The small player: artwork, what is playing, where it is, and the three
/// buttons. Laid out by hand at one fixed size, like Apple's.
final class PlayerViewController: NSViewController {
    private let artwork = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let elapsed = NSTextField(labelWithString: "")
    private let remaining = NSTextField(labelWithString: "")
    private let problem = NSTextField(labelWithString: "")
    private var playPause: NSButton!
    private var heart: NSButton!
    private var controls: [NSButton] = []
    private var timer: Timer?
    private var shownTrack: Track?

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 128))

        artwork.frame = NSRect(x: 14, y: 50, width: 64, height: 64)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 6
        artwork.layer?.masksToBounds = true

        titleLabel.frame = NSRect(x: 90, y: 90, width: 196, height: 18)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 90, y: 70, width: 196, height: 16)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let previous = button("backward.fill", #selector(previousTrack))
        playPause = button("playpause.fill", #selector(togglePlay))
        let next = button("forward.fill", #selector(nextTrack))
        heart = button("heart", #selector(toggleFavourite))
        for (index, control) in [previous, playPause!, next].enumerated() {
            control.frame = NSRect(x: 96 + CGFloat(index) * 46, y: 42, width: 32, height: 24)
            view.addSubview(control)
        }
        // Set apart from the transport, where Apple's player keeps it too.
        heart.frame = NSRect(x: 254, y: 44, width: 26, height: 20)
        view.addSubview(heart)
        controls = [previous, playPause!, next]

        progress.frame = NSRect(x: 14, y: 22, width: 272, height: 8)
        progress.isIndeterminate = false
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        for label in [elapsed, remaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        elapsed.frame = NSRect(x: 14, y: 6, width: 60, height: 14)
        remaining.frame = NSRect(x: 226, y: 6, width: 60, height: 14)
        remaining.alignment = .right

        // Shown instead of the playhead when a script is refused.
        problem.frame = NSRect(x: 14, y: 4, width: 272, height: 28)
        problem.font = .systemFont(ofSize: 10)
        problem.textColor = .systemOrange
        problem.maximumNumberOfLines = 2
        problem.lineBreakMode = .byWordWrapping

        [artwork, titleLabel, subtitle, progress, elapsed, remaining, problem].forEach(view.addSubview)
        self.view = view
    }

    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        return button
    }

    func show(_ track: Track?) {
        guard isViewLoaded else { return }
        let changedSong = track?.name != shownTrack?.name || track?.player != shownTrack?.player
        shownTrack = track
        titleLabel.stringValue = track?.name ?? "Nothing playing"
        subtitle.stringValue = [track?.artist, track?.album]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
        playPause.image = NSImage(systemSymbolName: track?.isPlaying == true ? "pause.fill" : "play.fill",
                                  accessibilityDescription: track?.isPlaying == true ? "Pause" : "Play")
        controls.forEach { $0.isEnabled = track != nil }
        let favourite = track == nil ? nil : NowPlayingMonitor.shared.favourite
        heart.isHidden = favourite == nil
        heart.image = NSImage(systemSymbolName: favourite == true ? "heart.fill" : "heart",
                              accessibilityDescription: favourite == true ? "Unfavourite" : "Favourite")
        heart.contentTintColor = favourite == true ? .systemPink : .secondaryLabelColor
        if track == nil {
            artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        } else if changedSong, let player = track?.player {
            artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            PlayerControl.artwork(of: player) { [weak self] image in
                guard let self = self, self.shownTrack?.player == player else { return }
                if let image = image { self.artwork.image = image }
            }
        }
        tick()
    }

    func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // The popover closing is the only signal that matters, and it is
            // not delivered to us; the view leaving its window is.
            guard self.view.window?.isVisible == true else {
                self.timer?.invalidate()
                self.timer = nil
                return
            }
            self.tick()
        }
    }

    private func tick() {
        guard let track = shownTrack else {
            [progress, elapsed, remaining].forEach { $0.isHidden = true }
            problem.isHidden = true
            return
        }
        let position = PlayerControl.position(of: track.player)
        let refused = PlayerControl.lastProblem
        problem.stringValue = refused ?? ""
        problem.isHidden = refused == nil
        let showsPlayhead = refused == nil && position != nil && track.duration != nil
        [progress, elapsed, remaining].forEach { $0.isHidden = !showsPlayhead }
        guard showsPlayhead, let position = position, let duration = track.duration else { return }
        progress.doubleValue = min(max(position / duration, 0), 1)
        elapsed.stringValue = Self.clock(position)
        remaining.stringValue = "-" + Self.clock(max(duration - position, 0))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func togglePlay() { command(.playPause) }
    @objc private func toggleFavourite() { NowPlayingMonitor.shared.toggleFavourite() }
    @objc private func nextTrack() { command(.next) }
    @objc private func previousTrack() { command(.previous) }

    /// The notification that follows updates the item and this view; the
    /// playhead is re-read straight away so the bar does not lag a second.
    private func command(_ command: PlayerControl.Command) {
        guard let player = shownTrack?.player else { return }
        PlayerControl.send(command, to: player)
        tick()
    }
}

/// Song mode's contents: the symbol, the title in a fixed-width window that
/// scrolls when the title is longer, and the heart. Views rather than a
/// button title because a title cannot be clipped and moved; they take the
/// bar's colour from the label colours, and they never take a click -- the
/// button underneath gets them all, so its highlight and action still work.
final class TitleStrip: NSView {
    /// Widest the title may get before it scrolls instead.
    static let maxTextWidth: CGFloat = 170
    /// The right-hand part of the item that counts as the heart.
    static let heartZone: CGFloat = 24

    private let icon = NSImageView()
    private let clip = NSView()
    private let label = NSTextField(labelWithString: "")
    private let heart = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var offset: CGFloat = 0
    private var pauseTicks = 0
    private var overflow: CGFloat = 0

    private static let padding: CGFloat = 6
    private static let iconWidth: CGFloat = 18
    private static let gap: CGFloat = 5
    /// Points per tick, and ticks per second: slow enough to read.
    private static let step: CGFloat = 1
    private static let rate: TimeInterval = 1.0 / 30
    /// Rests at each end, in ticks.
    private static let restAtStart = 60, restAtEnd = 45

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleNone
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        for field in [label, heart] {
            field.font = .menuBarFont(ofSize: 0)
            field.textColor = .labelColor
            field.lineBreakMode = .byClipping
        }
        clip.addSubview(label)
        [icon, clip, heart].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Lays everything out and returns the item length it needs.
    func show(icon image: NSImage?, text: String, favourite: Bool?, scrolling: Bool) -> CGFloat {
        icon.image = image
        let changed = label.stringValue != text
        label.stringValue = text
        label.sizeToFit()
        // U+FE0E keeps the filled heart from turning into a red emoji; text,
        // not an image, so a second display does not draw it mirrored.
        heart.stringValue = favourite.map { $0 ? "\u{2665}\u{FE0E}" : "\u{2661}" } ?? ""
        heart.sizeToFit()

        let textWidth = min(label.frame.width, Self.maxTextWidth)
        overflow = max(label.frame.width - Self.maxTextWidth, 0)
        let height = NSStatusBar.system.thickness
        var x = Self.padding
        icon.frame = NSRect(x: x, y: 0, width: Self.iconWidth, height: height)
        x += Self.iconWidth + Self.gap
        clip.frame = NSRect(x: x, y: 0, width: textWidth, height: height)
        x += textWidth
        if favourite != nil {
            x += Self.gap + 2
            heart.frame = NSRect(x: x, y: (height - heart.frame.height) / 2,
                                 width: heart.frame.width, height: heart.frame.height)
            x += heart.frame.width
        }
        heart.isHidden = favourite == nil

        if changed { offset = 0; pauseTicks = Self.restAtStart }
        placeLabel()
        // Only a playing song scrolls: a paused one sits still at its start,
        // and nothing ticks while nothing moves.
        if scrolling && overflow > 0 { start() } else { stop(); offset = 0; placeLabel() }
        return x + Self.padding
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.rate, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Rest at the start, glide left until the end of the title shows, rest,
    /// jump back.
    private func tick() {
        if pauseTicks > 0 { pauseTicks -= 1; return }
        if offset >= overflow {
            offset = 0
            pauseTicks = Self.restAtStart
        } else {
            offset = min(offset + Self.step, overflow)
            if offset >= overflow { pauseTicks = Self.restAtEnd }
        }
        placeLabel()
    }

    private func placeLabel() {
        let height = clip.bounds.height
        label.frame.origin = NSPoint(x: -offset, y: (height - label.frame.height) / 2)
    }
}
