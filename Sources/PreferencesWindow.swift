//
//  PreferencesWindow.swift
//  JustHide
//
//  One window, built in code: a header, the list of hidden apps, the options,
//  and a plain-English note about the quirks of how hiding works on macOS 27.
//  No storyboard to keep in sync.
//

import Cocoa
import Carbon.HIToolbox

final class PreferencesWindow: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindow()

    private var window: NSWindow?
    private var table: NSTableView?
    private var loginCheckbox: NSButton?
    private var hoverCheckbox: NSButton?
    private var clockCheckbox: NSButton?
    private var clockNote: NSTextField?
    private var glyphPopUp: NSPopUpButton?
    private var nowPlayingCheckbox: NSButton?
    private var nowPlayingStylePopUp: NSPopUpButton?
    private var nowPlayingWhenPopUp: NSPopUpButton?
    private var nowPlayingAppleNote: NSTextField?
    private var focusCheckbox: NSButton?
    private var focusWhenPopUp: NSPopUpButton?
    private var focusStatusNote: NSTextField?
    private var focusStatusButton: NSButton?
    private var autoHidePopUp: NSPopUpButton?
    private var shortcutButton: NSButton?
    private var shortcutClear: NSButton?
    private var quirksNote: NSTextField?
    private var quirksToggle: NSButton?
    private var quirksBox: NSView?
    private var quirksCollapsed: NSLayoutConstraint?
    private var accessRow: NSStackView?
    private var accessNote: NSTextField?
    private var accessButton: NSButton?
    private var accessRestartButton: NSButton?
    private var accessTop: NSLayoutConstraint?
    private var accessCollapsed: NSLayoutConstraint?
    private var mechanismRow: NSStackView?
    private var mechanismNote: NSTextField?
    private var mechanismButton: NSButton?
    private var mechanismTop: NSLayoutConstraint?
    private var mechanismCollapsed: NSLayoutConstraint?
    private var updateNote: NSTextField?
    private var updateButton: NSButton?
    private var updatesCheckbox: NSButton?
    private let picker = AppPicker()

    /// One line of the list: either an app, or -- indented under an app that
    /// owns several icons -- one of those icons.
    struct ListRow {
        let bundleID: String
        let name: String
        /// Set on an indented row standing for one icon.
        let item: MenuBarItemRef?
        /// On an app row, every icon that app owns.
        let children: [MenuBarItemRef]
        /// Set on a row standing for a shortcut whose icon can no longer be
        /// found. Kept visible so it can be removed: a binding with no row is a
        /// registered hotkey nobody can see or clear.
        var staleTarget: MenuBarItemTarget?

        var isChild: Bool { item != nil || staleTarget != nil }
        var isStale: Bool { staleTarget != nil }
        /// Only worth expanding when there is more than one icon to tell apart.
        var isExpandable: Bool { item == nil && children.count > 1 }

        /// What a shortcut on THIS row would open, or nil when this row cannot
        /// take one: an app whose icons each take their own, or an icon its app
        /// never named, which cannot be told from its siblings.
        var target: MenuBarItemTarget? {
            if let staleTarget = staleTarget { return staleTarget }
            if let item = item {
                return item.identity.map { .item(bundleID: bundleID, identity: $0) }
            }
            guard children.count <= 1 else { return nil }
            if let identity = children.first?.identity {
                return .item(bundleID: bundleID, identity: identity)
            }
            return .onlyItem(bundleID: bundleID)
        }
    }

    private var rows: [ListRow] = []
    private var expandedBundleIDs: Set<String> = []
    private var recordingTarget: MenuBarItemTarget?
    private var perAppNote: NSTextField?
    private var listHeight: NSLayoutConstraint?
    private var itemWatchTimer: Timer?
    /// What the list was last built from, so a poll that finds nothing changed
    /// does not rebuild the table and throw away the selection.
    private var lastItemSignature: String?
    /// Guards the delayed reset of a flashed message, so an older flash cannot
    /// wipe a newer one.
    private var flashToken = 0

    static let perAppNoteText = "Hiding applies to a whole app, not to one of its icons. "
        + "A shortcut opens one icon\u{2019}s own menu, hidden or not."
    /// While true the next keystroke is captured as the shortcut.
    private var recordingShortcut = false
    private var keyMonitor: Any?

    func show() {
        if window == nil { build() }
        reload()
        startWatchingItems()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        itemWatchTimer?.invalidate()
        itemWatchTimer = nil
    }

    /// Icons come and go inside an app while nothing launches or quits -- adding
    /// a readout in Vorssaint is a case in point -- so there is no notification
    /// to wait for. The newcomer watch in the controller only sees PROCESSES
    /// starting, which is the right signal for hiding (that is per app anyway)
    /// and the wrong one for this.
    ///
    /// So: poll, but only while the window is actually on screen, and only
    /// rebuild when the set of icons really changed.
    private func startWatchingItems() {
        itemWatchTimer?.invalidate()
        itemWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            // Not mid-recording: rebuilding the table under a row that is
            // waiting for keys is asking for trouble.
            guard self.recordingTarget == nil, !self.recordingShortcut else { return }
            guard self.itemSignature() != self.lastItemSignature else { return }
            Log.controller.log("menu bar icons changed; refreshing the list")
            self.reload()
        }
    }

    /// Every listed app and the icons it publishes, as one string to compare.
    private func itemSignature() -> String {
        Settings.listedBundleIDs.sorted().map { bundleID in
            let items = MenuBarItemCatalogue.discover(bundleID: bundleID)
            return bundleID + "=" + items.map { $0.identity ?? $0.label }.joined(separator: ",")
        }.joined(separator: "|")
    }

    /// Granting Accessibility happens in System Settings, over in another app, so
    /// the window has no way of hearing about it. Coming back to JustHide is the
    /// signal: re-read everything then.
    @objc private func windowBecameActive() {
        guard window?.isVisible == true else { return }
        reload()
    }

    // MARK: - Building

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 620),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "JustHide Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView()
        window.contentView = content

        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameActive),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)

        // ---- Header: icon, name, version
        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let name = label("JustHide", size: 22, bold: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let subtitle = label("Tidies your menu bar. Version \(version).", secondary: true)

        let updateNote = label("", secondary: true)
        updateNote.maximumNumberOfLines = 0
        // Without this a long line widens the WINDOW instead of wrapping: the
        // row sits beside the header, so nothing else constrains its width.
        updateNote.preferredMaxLayoutWidth = 240
        self.updateNote = updateNote
        let updateButton = NSButton(title: "Check Now", target: self,
                                    action: #selector(updateAction))
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        self.updateButton = updateButton
        // A plain button rather than a link: a link in a window nobody expects
        // to be clickable is a guessing game, and this is the only outward
        // pointer in the app.
        let githubButton = NSButton(title: "GitHub", target: self, action: #selector(openProjectPage))
        githubButton.bezelStyle = .rounded
        githubButton.controlSize = .small
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        let updateRow = NSStackView(views: [updateNote, updateButton, githubButton])
        updateRow.orientation = .horizontal
        updateRow.spacing = 8
        updateRow.translatesAutoresizingMaskIntoConstraints = false

        // ---- Hidden apps
        let listLabel = label("Menu bar apps", bold: true)

        let table = NSTableView()
        table.rowHeight = 24
        table.style = .inset
        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "App"
        appColumn.resizingMask = .autoresizingMask
        table.addTableColumn(appColumn)
        // Headers now that there are two control columns: which tick box does
        // what would otherwise be a guess.
        let hiddenColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hidden"))
        hiddenColumn.title = "Hidden"
        hiddenColumn.width = 48
        hiddenColumn.minWidth = 48
        hiddenColumn.maxWidth = 48
        hiddenColumn.resizingMask = []
        table.addTableColumn(hiddenColumn)
        // Fixed: a shortcut of up to four modifiers plus a key, and the button
        // that removes it.
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.width = 104
        keyColumn.minWidth = 104
        keyColumn.maxWidth = 104
        keyColumn.title = "Shortcut"
        keyColumn.resizingMask = []
        table.addTableColumn(keyColumn)
        table.dataSource = self
        table.delegate = self
        self.table = table

        let scroll = NSScrollView()
        // Sized to its contents, between six and fourteen rows: enough that a
        // busy menu bar does not scroll straight away, capped so the window
        // cannot grow without end. reload() sets the constant.
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 172)
        self.listHeight = listHeight
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let listButtons = NSSegmentedControl(labels: ["+", "\u{2212}", "\u{21BB}"],
                                             trackingMode: .momentary,
                                             target: self, action: #selector(addOrRemove(_:)))
        listButtons.segmentStyle = .smallSquare
        listButtons.translatesAutoresizingMaskIntoConstraints = false

        let perAppNote = label(Self.perAppNoteText, secondary: true)
        perAppNote.maximumNumberOfLines = 0
        perAppNote.preferredMaxLayoutWidth = 520 - 40 - 100
        self.perAppNote = perAppNote

        // No Accessibility row. Hiding works without the permission -- it is only
        // needed to LIST what is in the bar right now -- so a standing orange
        // warning here was a nag for something that breaks nothing. The ask now
        // lives in the app picker, which is the one place it makes a difference,
        // and the list's third button re-reads it.

        // ---- Accessibility. Collapsed to nothing unless something the user has
        // actually switched on needs the permission, so it is never a standing
        // nag: hiding itself works without it.
        let accessNote = label("", secondary: true)
        accessNote.textColor = .systemOrange
        accessNote.maximumNumberOfLines = 0
        accessNote.preferredMaxLayoutWidth = 520 - 40
        self.accessNote = accessNote
        let accessButton = NSButton(title: "Allow\u{2026}", target: self,
                                    action: #selector(allowAccessibility))
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        accessButton.translatesAutoresizingMaskIntoConstraints = false
        self.accessButton = accessButton
        let accessRestartButton = NSButton(title: "Restart JustHide", target: self,
                                           action: #selector(restartForAccessibility))
        accessRestartButton.bezelStyle = .rounded
        accessRestartButton.controlSize = .small
        accessRestartButton.translatesAutoresizingMaskIntoConstraints = false
        self.accessRestartButton = accessRestartButton
        let accessButtons = NSStackView(views: [accessButton, accessRestartButton])
        accessButtons.orientation = .horizontal
        accessButtons.spacing = 8
        let accessRow = NSStackView(views: [accessNote, accessButtons])
        accessRow.orientation = .vertical
        accessRow.alignment = .leading
        accessRow.spacing = 6
        accessRow.translatesAutoresizingMaskIntoConstraints = false
        self.accessRow = accessRow

        // ---- How hiding is going. Collapsed to nothing while it is going
        // fine, which is nearly always -- but when it is not, this is the only
        // place that explains it and the only way to the other mechanism.
        let mechanismNote = label("", secondary: true)
        mechanismNote.textColor = .systemOrange
        mechanismNote.maximumNumberOfLines = 0
        mechanismNote.preferredMaxLayoutWidth = 520 - 40
        self.mechanismNote = mechanismNote
        let mechanismButton = NSButton(title: "", target: self, action: #selector(switchMechanism))
        mechanismButton.bezelStyle = .rounded
        mechanismButton.controlSize = .small
        mechanismButton.translatesAutoresizingMaskIntoConstraints = false
        self.mechanismButton = mechanismButton
        let mechanismRow = NSStackView(views: [mechanismNote, mechanismButton])
        mechanismRow.orientation = .vertical
        mechanismRow.alignment = .leading
        mechanismRow.spacing = 6
        mechanismRow.translatesAutoresizingMaskIntoConstraints = false
        self.mechanismRow = mechanismRow

        // ---- Options
        let optionsLabel = label("Behaviour", bold: true)

        let loginCheckbox = NSButton(checkboxWithTitle: "Open JustHide at login",
                                     target: self, action: #selector(toggleLogin))
        loginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        self.loginCheckbox = loginCheckbox

        let hoverCheckbox = NSButton(checkboxWithTitle: "Reveal on hover in the menu bar",
                                     target: self, action: #selector(toggleHover))
        hoverCheckbox.translatesAutoresizingMaskIntoConstraints = false
        self.hoverCheckbox = hoverCheckbox

        let clockCheckbox = NSButton(checkboxWithTitle: "Clock opens Notification Center",
                                     target: self, action: #selector(toggleClockClickThrough))
        clockCheckbox.translatesAutoresizingMaskIntoConstraints = false
        self.clockCheckbox = clockCheckbox

        // The cost sits under the checkbox rather than only in "Good to know":
        // it is specific to this choice, so it belongs where the choice is made.
        let clockNote = label("macOS blocks Notification Center while icons are hidden. Clicking "
                              + "the clock unhides for a moment so it opens; closing it hides "
                              + "again. Your icons are back while Notification Center is open.",
                              secondary: true)
        clockNote.maximumNumberOfLines = 0
        clockNote.preferredMaxLayoutWidth = 520 - 40 - 20
        self.clockNote = clockNote

        let updatesCheckbox = NSButton(checkboxWithTitle: "Check GitHub for new versions",
                                       target: self, action: #selector(toggleUpdateChecks))
        updatesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        updatesCheckbox.toolTip = "Once a day, and nothing about you is sent."
        self.updatesCheckbox = updatesCheckbox

        let autoHideLabel = label("Hide again after:")
        let autoHidePopUp = NSPopUpButton()
        for option in Self.autoHideOptions {
            autoHidePopUp.addItem(withTitle: option.label)
            autoHidePopUp.lastItem?.representedObject = option.seconds
        }
        autoHidePopUp.target = self
        autoHidePopUp.action = #selector(changeAutoHide)
        autoHidePopUp.translatesAutoresizingMaskIntoConstraints = false
        self.autoHidePopUp = autoHidePopUp

        let shortcutLabel = label("Keyboard shortcut:")
        let shortcutButton = NSButton(title: "None", target: self, action: #selector(recordShortcut))
        shortcutButton.bezelStyle = .rounded
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        self.shortcutButton = shortcutButton
        // Same reasoning as the per-icon rows: Escape while recording clears it,
        // which is not something anyone would find on their own.
        let shortcutClear = NSButton(title: "", target: self, action: #selector(clearShortcut))
        shortcutClear.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                      accessibilityDescription: "Remove this shortcut")
        shortcutClear.isBordered = false
        shortcutClear.controlSize = .small
        shortcutClear.contentTintColor = .secondaryLabelColor
        shortcutClear.toolTip = "Remove this shortcut"
        shortcutClear.translatesAutoresizingMaskIntoConstraints = false
        self.shortcutClear = shortcutClear

        let glyphLabel = label("Menu bar symbol:")
        let glyphPopUp = NSPopUpButton()
        for glyph in Settings.Glyph.allCases {
            glyphPopUp.addItem(withTitle: glyph.label)
            glyphPopUp.lastItem?.representedObject = glyph.rawValue
        }
        glyphPopUp.target = self
        glyphPopUp.action = #selector(changeGlyph)
        glyphPopUp.translatesAutoresizingMaskIntoConstraints = false
        self.glyphPopUp = glyphPopUp

        // ---- Now Playing. Its own section: it is a feature of its own rather
        // than a way of hiding, and it has three settings of its own.
        let nowPlayingLabel = label("Now Playing", bold: true)
        let nowPlayingCheckbox = NSButton(checkboxWithTitle: "Show Now Playing for Music and Spotify",
                                          target: self, action: #selector(toggleNowPlaying))
        nowPlayingCheckbox.translatesAutoresizingMaskIntoConstraints = false
        self.nowPlayingCheckbox = nowPlayingCheckbox
        let nowPlayingNote = label("Unlike Apple\u{2019}s, it stays while icons are hidden. Click it for "
                                   + "the player; with the song showing, the heart at the end favourites "
                                   + "it in Music (Spotify\u{2019}s scripting has no favourites). The "
                                   + "controls ask once for permission to control each player.",
                                   secondary: true)
        nowPlayingNote.maximumNumberOfLines = 0

        let nowPlayingStyleLabel = label("In the menu bar:")
        let nowPlayingStylePopUp = NSPopUpButton()
        for (title, style) in [("Icon", Settings.NowPlayingStyle.icon),
                               ("Icon and song", Settings.NowPlayingStyle.title)] {
            nowPlayingStylePopUp.addItem(withTitle: title)
            nowPlayingStylePopUp.lastItem?.representedObject = style.rawValue
        }
        nowPlayingStylePopUp.target = self
        nowPlayingStylePopUp.action = #selector(changeNowPlayingStyle)
        nowPlayingStylePopUp.translatesAutoresizingMaskIntoConstraints = false
        self.nowPlayingStylePopUp = nowPlayingStylePopUp

        let nowPlayingWhenLabel = label("Show it:")
        let nowPlayingWhenPopUp = NSPopUpButton()
        for (title, when) in [("While playing or paused", Settings.NowPlayingAppearance.whilePlaying),
                              ("Always", Settings.NowPlayingAppearance.always)] {
            nowPlayingWhenPopUp.addItem(withTitle: title)
            nowPlayingWhenPopUp.lastItem?.representedObject = when.rawValue
        }
        nowPlayingWhenPopUp.target = self
        nowPlayingWhenPopUp.action = #selector(changeNowPlayingWhen)
        nowPlayingWhenPopUp.translatesAutoresizingMaskIntoConstraints = false
        self.nowPlayingWhenPopUp = nowPlayingWhenPopUp

        // Apple's own is the user's setting, so this says how it is and opens
        // the page rather than changing it (see Settings.appleNowPlayingIsOn).
        let nowPlayingAppleNote = label("", secondary: true)
        nowPlayingAppleNote.maximumNumberOfLines = 0
        self.nowPlayingAppleNote = nowPlayingAppleNote
        let nowPlayingAppleButton = NSButton(title: "Open Menu Bar Settings\u{2026}", target: self,
                                             action: #selector(openMenuBarSettings))
        nowPlayingAppleButton.bezelStyle = .rounded
        nowPlayingAppleButton.controlSize = .small
        nowPlayingAppleButton.translatesAutoresizingMaskIntoConstraints = false

        // ---- Focus. Built like Now Playing, with one status line and one
        // button that say whichever thing matters most: missing Full Disk
        // Access first, then whether Apple's own is still on.
        let focusLabel = label("Focus", bold: true)
        let focusCheckbox = NSButton(checkboxWithTitle: "Show the current Focus",
                                     target: self, action: #selector(toggleFocus))
        focusCheckbox.translatesAutoresizingMaskIntoConstraints = false
        self.focusCheckbox = focusCheckbox
        let focusNote = label("Unlike Apple\u{2019}s, it stays while icons are hidden, with each "
                              + "Focus\u{2019}s own symbol. Click it for the Focus modes \u{2014} "
                              + "macOS only lets another app reach them through Control Centre, so "
                              + "Control Centre opens first and then switches to them. Needs Full "
                              + "Disk Access, to read which Focus is on, and Accessibility, to open "
                              + "the modes.", secondary: true)
        focusNote.maximumNumberOfLines = 0

        let focusWhenLabel = label("Show it:")
        let focusWhenPopUp = NSPopUpButton()
        for (title, when) in [("While a Focus is on", Settings.FocusAppearance.whileOn),
                              ("Always", Settings.FocusAppearance.always)] {
            focusWhenPopUp.addItem(withTitle: title)
            focusWhenPopUp.lastItem?.representedObject = when.rawValue
        }
        focusWhenPopUp.target = self
        focusWhenPopUp.action = #selector(changeFocusWhen)
        focusWhenPopUp.translatesAutoresizingMaskIntoConstraints = false
        self.focusWhenPopUp = focusWhenPopUp

        let focusStatusNote = label("", secondary: true)
        focusStatusNote.maximumNumberOfLines = 0
        self.focusStatusNote = focusStatusNote
        let focusStatusButton = NSButton(title: "", target: self, action: #selector(focusStatusAction))
        focusStatusButton.bezelStyle = .rounded
        focusStatusButton.controlSize = .small
        focusStatusButton.translatesAutoresizingMaskIntoConstraints = false
        self.focusStatusButton = focusStatusButton

        // ---- Quirks, behind a disclosure. In one column this block is the
        // single biggest thing in the window, and it is reference material: read
        // once, then in the way. Collapsed by default, and the state sticks.
        let quirksToggle = NSButton(title: "", target: self, action: #selector(toggleQuirks))
        quirksToggle.bezelStyle = .disclosure
        quirksToggle.setButtonType(.onOff)
        quirksToggle.state = Settings.showsGoodToKnow ? .on : .off
        quirksToggle.translatesAutoresizingMaskIntoConstraints = false
        self.quirksToggle = quirksToggle
        let quirksLabel = label("Good to know", bold: true)
        let quirks = label(Self.quirksText, secondary: true)
        quirksNote = quirks
        quirks.maximumNumberOfLines = 0
        // Without a wrapping width an NSTextField lays out on one line and runs
        // straight off the window: 520 wide, less the window margins and the
        // box's own content margins.
        // Wraps to the box's inner width: window 520, less both window margins
        // and the box's own padding.
        quirks.preferredMaxLayoutWidth = 520 - 40 - 24
        // A plain layer-backed view rather than NSBox: NSBox positions its
        // contentView by frame, which fights the label's constraints and spilled
        // the text out above the box.
        let quirksBox = NSView()
        quirksBox.wantsLayer = true
        quirksBox.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        quirksBox.layer?.borderColor = NSColor.separatorColor.cgColor
        quirksBox.layer?.borderWidth = 1
        quirksBox.layer?.cornerRadius = 6
        quirksBox.translatesAutoresizingMaskIntoConstraints = false
        quirksBox.addSubview(quirks)
        self.quirksBox = quirksBox
        NSLayoutConstraint.activate([
            quirks.topAnchor.constraint(equalTo: quirksBox.topAnchor, constant: 10),
            quirks.leadingAnchor.constraint(equalTo: quirksBox.leadingAnchor, constant: 12),
            quirks.trailingAnchor.constraint(equalTo: quirksBox.trailingAnchor, constant: -12),
            quirks.bottomAnchor.constraint(equalTo: quirksBox.bottomAnchor, constant: -10),
        ])

        for view in [iconView, name, subtitle, updateRow, listLabel, scroll, listButtons, perAppNote,
                     quirksToggle,
                     accessRow, mechanismRow, optionsLabel,
                     loginCheckbox, hoverCheckbox, clockCheckbox, clockNote,
                     updatesCheckbox, autoHideLabel, autoHidePopUp,
                     shortcutLabel, shortcutButton, shortcutClear, glyphLabel, glyphPopUp,
                     nowPlayingLabel, nowPlayingCheckbox, nowPlayingNote,
                     nowPlayingStyleLabel, nowPlayingStylePopUp, nowPlayingWhenLabel,
                     nowPlayingWhenPopUp, nowPlayingAppleNote, nowPlayingAppleButton,
                     focusLabel, focusCheckbox, focusNote, focusWhenLabel, focusWhenPopUp,
                     focusStatusNote, focusStatusButton,
                     quirksLabel, quirksBox] {
            content.addSubview(view)
        }

        // ---- Layout
        //
        // The hiding settings are one column, 700pt wide rather than the
        // original 520: prose that wrapped to four lines at 520 takes two, and
        // the pop-ups sit beside their labels. An earlier two-column version was
        // rejected because it split HIDING across two panes. This one splits by
        // topic instead: Now Playing and Focus, the items JustHide adds to the
        // bar, go in a column of their own on the right, since in one column
        // the window had grown taller than a laptop screen.
        let margin: CGFloat = 20
        let leftWidth = Self.leftColumnWidth
        let windowWidth = Self.windowWidth
        let controlColumn = content.leadingAnchor
        // The right column holds the two items JustHide adds to the bar, Now
        // Playing and Focus: things it SHOWS, beside the things it hides. A
        // second column rather than more height, because one column had
        // grown past the height of a laptop screen.
        let rightColumn = content.leadingAnchor
        let rightInset = leftWidth + margin
        let rightInner = windowWidth - leftWidth - 2 * margin
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        perAppNote.preferredMaxLayoutWidth = leftWidth - 2 * margin - 120
        clockNote.preferredMaxLayoutWidth = leftWidth - 2 * margin - 18
        nowPlayingNote.preferredMaxLayoutWidth = rightInner - 18
        nowPlayingAppleNote.preferredMaxLayoutWidth = rightInner
        focusNote.preferredMaxLayoutWidth = rightInner - 18
        focusStatusNote.preferredMaxLayoutWidth = rightInner
        quirks.preferredMaxLayoutWidth = leftWidth - 2 * margin - 24

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            iconView.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            name.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            subtitle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: name.leadingAnchor),

            updateRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),
            updateRow.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            updateRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                                constant: -margin),

            // Notices under the header: a warning is worth seeing first, and one
            // anchor chain is much easier to collapse than something buried
            // mid-window.
            accessRow.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            accessRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            mechanismRow.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            mechanismRow.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                   constant: -margin),

            // ---- The list
            listLabel.topAnchor.constraint(equalTo: mechanismRow.bottomAnchor, constant: 16),
            listLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            scroll.topAnchor.constraint(equalTo: listLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            scroll.trailingAnchor.constraint(equalTo: controlColumn, constant: leftWidth - margin),
            listHeight,

            listButtons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.widthAnchor.constraint(equalToConstant: 108),

            // Back beside the buttons rather than under them: there is width for
            // it now, and it saves a line.
            perAppNote.centerYAnchor.constraint(equalTo: listButtons.centerYAnchor),
            perAppNote.leadingAnchor.constraint(equalTo: listButtons.trailingAnchor, constant: 12),
            perAppNote.trailingAnchor.constraint(lessThanOrEqualTo: controlColumn,
                                                 constant: leftWidth - margin),

            // ---- The options
            optionsLabel.topAnchor.constraint(equalTo: listButtons.bottomAnchor, constant: 18),
            optionsLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            loginCheckbox.topAnchor.constraint(equalTo: optionsLabel.bottomAnchor, constant: 8),
            loginCheckbox.leadingAnchor.constraint(equalTo: optionsLabel.leadingAnchor),

            hoverCheckbox.topAnchor.constraint(equalTo: loginCheckbox.bottomAnchor, constant: 6),
            hoverCheckbox.leadingAnchor.constraint(equalTo: optionsLabel.leadingAnchor),

            clockCheckbox.topAnchor.constraint(equalTo: hoverCheckbox.bottomAnchor, constant: 6),
            clockCheckbox.leadingAnchor.constraint(equalTo: optionsLabel.leadingAnchor),

            // Indented to the checkbox's text, so it reads as that option's
            // small print rather than as another setting.
            clockNote.topAnchor.constraint(equalTo: clockCheckbox.bottomAnchor, constant: 2),
            clockNote.leadingAnchor.constraint(equalTo: optionsLabel.leadingAnchor, constant: 18),
            clockNote.trailingAnchor.constraint(equalTo: controlColumn, constant: leftWidth - margin),

            updatesCheckbox.topAnchor.constraint(equalTo: clockNote.bottomAnchor, constant: 8),
            updatesCheckbox.leadingAnchor.constraint(equalTo: optionsLabel.leadingAnchor),

            autoHideLabel.topAnchor.constraint(equalTo: updatesCheckbox.bottomAnchor, constant: 14),
            autoHideLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            autoHidePopUp.centerYAnchor.constraint(equalTo: autoHideLabel.centerYAnchor),
            autoHidePopUp.leadingAnchor.constraint(equalTo: controlColumn, constant: 170),
            autoHidePopUp.widthAnchor.constraint(equalToConstant: 220),

            shortcutLabel.topAnchor.constraint(equalTo: autoHideLabel.bottomAnchor, constant: 14),
            shortcutLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            shortcutButton.centerYAnchor.constraint(equalTo: shortcutLabel.centerYAnchor),
            shortcutButton.leadingAnchor.constraint(equalTo: autoHidePopUp.leadingAnchor),
            shortcutButton.widthAnchor.constraint(equalToConstant: 220),
            shortcutClear.leadingAnchor.constraint(equalTo: shortcutButton.trailingAnchor,
                                                   constant: 6),
            shortcutClear.centerYAnchor.constraint(equalTo: shortcutButton.centerYAnchor),
            shortcutClear.widthAnchor.constraint(equalToConstant: 16),

            glyphLabel.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 14),
            glyphLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            glyphPopUp.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
            glyphPopUp.leadingAnchor.constraint(equalTo: autoHidePopUp.leadingAnchor),
            glyphPopUp.widthAnchor.constraint(equalToConstant: 220),

            // ---- The right column, level with the list
            divider.topAnchor.constraint(equalTo: listLabel.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            divider.leadingAnchor.constraint(equalTo: controlColumn, constant: leftWidth),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // ---- Now Playing
            nowPlayingLabel.topAnchor.constraint(equalTo: listLabel.topAnchor),
            nowPlayingLabel.leadingAnchor.constraint(equalTo: rightColumn, constant: rightInset),

            nowPlayingCheckbox.topAnchor.constraint(equalTo: nowPlayingLabel.bottomAnchor, constant: 8),
            nowPlayingCheckbox.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor),

            nowPlayingNote.topAnchor.constraint(equalTo: nowPlayingCheckbox.bottomAnchor, constant: 2),
            nowPlayingNote.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor, constant: 18),
            nowPlayingNote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            nowPlayingStyleLabel.topAnchor.constraint(equalTo: nowPlayingNote.bottomAnchor, constant: 12),
            nowPlayingStyleLabel.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor),
            nowPlayingStylePopUp.centerYAnchor.constraint(equalTo: nowPlayingStyleLabel.centerYAnchor),
            nowPlayingStylePopUp.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor, constant: 120),
            nowPlayingStylePopUp.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            nowPlayingWhenLabel.topAnchor.constraint(equalTo: nowPlayingStyleLabel.bottomAnchor, constant: 14),
            nowPlayingWhenLabel.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor),
            nowPlayingWhenPopUp.centerYAnchor.constraint(equalTo: nowPlayingWhenLabel.centerYAnchor),
            nowPlayingWhenPopUp.leadingAnchor.constraint(equalTo: nowPlayingStylePopUp.leadingAnchor),
            nowPlayingWhenPopUp.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            nowPlayingAppleNote.topAnchor.constraint(equalTo: nowPlayingWhenLabel.bottomAnchor, constant: 12),
            nowPlayingAppleNote.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor),
            nowPlayingAppleNote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            nowPlayingAppleButton.topAnchor.constraint(equalTo: nowPlayingAppleNote.bottomAnchor, constant: 6),
            nowPlayingAppleButton.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor),

            // ---- Focus
            focusLabel.topAnchor.constraint(equalTo: nowPlayingAppleButton.bottomAnchor, constant: 22),
            focusLabel.leadingAnchor.constraint(equalTo: nowPlayingLabel.leadingAnchor),

            focusCheckbox.topAnchor.constraint(equalTo: focusLabel.bottomAnchor, constant: 8),
            focusCheckbox.leadingAnchor.constraint(equalTo: focusLabel.leadingAnchor),

            focusNote.topAnchor.constraint(equalTo: focusCheckbox.bottomAnchor, constant: 2),
            focusNote.leadingAnchor.constraint(equalTo: focusLabel.leadingAnchor, constant: 18),
            focusNote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            focusWhenLabel.topAnchor.constraint(equalTo: focusNote.bottomAnchor, constant: 12),
            focusWhenLabel.leadingAnchor.constraint(equalTo: focusLabel.leadingAnchor),
            focusWhenPopUp.centerYAnchor.constraint(equalTo: focusWhenLabel.centerYAnchor),
            focusWhenPopUp.leadingAnchor.constraint(equalTo: nowPlayingStylePopUp.leadingAnchor),
            focusWhenPopUp.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            focusStatusNote.topAnchor.constraint(equalTo: focusWhenLabel.bottomAnchor, constant: 12),
            focusStatusNote.leadingAnchor.constraint(equalTo: focusLabel.leadingAnchor),
            focusStatusNote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            focusStatusButton.topAnchor.constraint(equalTo: focusStatusNote.bottomAnchor, constant: 6),
            focusStatusButton.leadingAnchor.constraint(equalTo: focusLabel.leadingAnchor),
            // The window grows to whichever column is taller.
            focusStatusButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor,
                                                      constant: -margin),

            // ---- The notes, behind their triangle
            quirksToggle.topAnchor.constraint(equalTo: glyphLabel.bottomAnchor, constant: 18),
            quirksToggle.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            quirksLabel.centerYAnchor.constraint(equalTo: quirksToggle.centerYAnchor),
            quirksLabel.leadingAnchor.constraint(equalTo: quirksToggle.trailingAnchor, constant: 4),

            quirksBox.topAnchor.constraint(equalTo: quirksToggle.bottomAnchor, constant: 6),
            quirksBox.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            quirksBox.trailingAnchor.constraint(equalTo: controlColumn, constant: leftWidth - margin),
            quirksBox.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor,
                                              constant: -margin),
        ])

        self.quirksCollapsed = quirksBox.heightAnchor.constraint(equalToConstant: 0)

        // The mechanism row's height is its content, not a constant: the note
        // wraps to however many lines it needs. Only the collapsed state is a
        // fixed height, so that constraint is the one switched on and off.
        let accessTop = accessRow.topAnchor.constraint(equalTo: updateRow.bottomAnchor,
                                                       constant: 0)
        accessTop.isActive = true
        self.accessTop = accessTop
        self.accessCollapsed = accessRow.heightAnchor.constraint(equalToConstant: 0)

        let mechanismTop = mechanismRow.topAnchor.constraint(equalTo: accessRow.bottomAnchor,
                                                             constant: 12)
        mechanismTop.isActive = true
        self.mechanismTop = mechanismTop
        self.mechanismCollapsed = mechanismRow.heightAnchor.constraint(equalToConstant: 0)

        applyQuirksState()
        applyAccessibilityState()
        applyMechanismState()
        applyUpdateState()

        NotificationCenter.default.addObserver(self, selector: #selector(mechanismChanged),
                                               name: .justHideMechanismChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateChanged),
                                               name: .justHideUpdateChanged, object: nil)

        // Fit the window to the content rather than to a guessed height.
        content.layoutSubtreeIfNeeded()
        let needed = content.fittingSize
        window.setContentSize(NSSize(width: Self.windowWidth, height: max(needed.height + margin, 480)))

        self.window = window
    }

    /// The original single column, and the right-hand one for the items
    /// JustHide adds to the bar.
    private static let leftColumnWidth: CGFloat = 700
    private static let windowWidth: CGFloat = 1080

    /// Written for someone who did not implement it: what is surprising, and why.
    private static var quirksText: String {
        // Kept tight on purpose: this sits in a column, and a wall of text is
        // one nobody reads.
        var notes = [
            "• Hiding works per app, not per icon \u{2014} an app with several icons hides "
            + "all of them together.",
            "• Position means nothing here: a hidden icon is not moved aside, it is not "
            + "drawn at all. macOS places each icon and remembers it per app, so one can "
            + "sit either side of the JustHide symbol. \u{2318}-drag to rearrange.",
            "• A shortcut opens an icon\u{2019}s own menu in place without unhiding it; press "
            + "again to close. Needs Accessibility, and the app must be running.",
            "• While anything is hidden, macOS also hides its own Now Playing and Focus "
            + "icons. JustHide\u{2019}s own versions stay; to avoid seeing two of each while "
            + "icons are revealed, set Apple\u{2019}s to \u{201C}Don\u{2019}t Show\u{201D} under "
            + "Menu Bar in System Settings. JustHide\u{2019}s Focus opens the modes through "
            + "Control Centre, the only way another app can reach them.",
        ]
        if Settings.clockClickThrough {
            notes.append("• Clicking the clock unhides briefly so Notification Center opens, "
                         + "and hides again when you close it \u{2014} macOS will not open it "
                         + "while icons are hidden.")
        } else {
            notes.append("• While icons are hidden, clicking the clock will not open "
                         + "Notification Center. Swipe in from the right edge, or turn on the "
                         + "clock option above.")
        }
        if Mechanism.current == .concealment {
            notes.append("• Hiding uses an undocumented part of macOS 27. If an update takes it "
                         + "away, JustHide says so on its symbol and offers its older method.")
        }
        return notes.joined(separator: "\n")
    }

    private static let autoHideOptions: [(label: String, seconds: Double)] = [
        ("Never", 0), ("5 seconds", 5), ("10 seconds", 10),
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
    ]

    private func label(_ text: String, size: CGFloat? = nil,
                       bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        let pointSize = size ?? (secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        field.font = bold ? .boldSystemFont(ofSize: pointSize) : .systemFont(ofSize: pointSize)
        if secondary { field.textColor = .secondaryLabelColor }
        field.lineBreakMode = .byWordWrapping
        return field
    }

    // MARK: - Contents

    /// The hidden apps, each followed by its own icons when it owns several and
    /// the user has opened it up.
    private func buildRows() -> [ListRow] {
        let apps = Settings.listedBundleIDs
            .map { (name: MenuBarApps.displayName(for: $0), bundleID: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var built: [ListRow] = []
        for app in apps {
            let items = MenuBarItemCatalogue.items(for: app.bundleID)
            // A shortcut whose identity no longer matches anything the app
            // publishes. It happens for real: Vorssaint names its icons through
            // AXHelp, and its main icon's help text carries the current state
            // ("Vorssaint: awake indefinitely"), so that one changes under us.
            let known = Set(items.compactMap(\.identity))
            let stale = Settings.itemShortcuts.keys.filter { target in
                guard target.bundleID == app.bundleID else { return false }
                if case let .item(_, identity) = target { return !known.contains(identity) }
                return false
            }
            built.append(ListRow(bundleID: app.bundleID, name: app.name,
                                 item: nil, children: items))
            // Forced open when something needs attention, so a stale row cannot
            // hide inside a collapsed app.
            let open = expandedBundleIDs.contains(app.bundleID) || !stale.isEmpty
            guard items.count > 1 || !stale.isEmpty, open else { continue }
            for item in items {
                built.append(ListRow(bundleID: app.bundleID, name: item.label,
                                     item: item, children: []))
            }
            for target in stale.sorted(by: { $0.storageKey < $1.storageKey }) {
                guard case let .item(_, identity) = target else { continue }
                built.append(ListRow(bundleID: app.bundleID, name: identity,
                                     item: nil, children: [], staleTarget: target))
            }
        }
        return built
    }

    private func reload() {
        rows = buildRows()
        lastItemSignature = itemSignature()
        table?.reloadData()
        let wanted = min(max(rows.count, 6), 14) * 24 + 8
        if listHeight?.constant != CGFloat(wanted) {
            listHeight?.constant = CGFloat(wanted)
            fitWindow()
        }

        loginCheckbox?.state = LaunchAtLogin.isEnabled ? .on : .off
        loginCheckbox?.title = LaunchAtLogin.needsApproval
            ? "Open JustHide at login (approve it in System Settings)"
            : "Open JustHide at login"
        hoverCheckbox?.state = Settings.hoverToReveal ? .on : .off
        clockCheckbox?.state = Settings.clockClickThrough ? .on : .off
        updatesCheckbox?.state = Settings.checksForUpdates ? .on : .off

        glyphPopUp?.selectItem(at: Settings.Glyph.allCases.firstIndex(of: Settings.glyph) ?? 0)
        applyNowPlayingState()
        applyFocusState()
        if let index = Self.autoHideOptions.firstIndex(where: { $0.seconds == Settings.autoHideDelay }) {
            autoHidePopUp?.selectItem(at: index)
        }
        if !recordingShortcut {
            shortcutButton?.title = Settings.hotkeyDescription
        }
        shortcutClear?.isHidden = Settings.hotkey == nil || recordingShortcut
        // Hover reveal is part of the concealment controller only; the width
        // mechanism has no cheap way to do it, so the box says so rather than
        // offering a switch that does nothing.
        hoverCheckbox?.isEnabled = Mechanism.current == .concealment
        hoverCheckbox?.toolTip = Mechanism.current == .concealment
            ? nil : "Not available while JustHide is using its older method."

        // Likewise: the clock is only blocked by the concealment assertion, so
        // with the width mechanism there is nothing for this to fix. It also
        // needs Accessibility, to find where the clock is.
        let clockAvailable = Mechanism.current == .concealment
        clockCheckbox?.isEnabled = clockAvailable
        clockCheckbox?.toolTip = clockAvailable
            ? (AXIsProcessTrusted() ? nil : "Needs the Accessibility permission, to find the clock.")
            : "Not available while JustHide is using its older method."
        clockNote?.textColor = clockAvailable ? .secondaryLabelColor : .tertiaryLabelColor

        // The notes depend on the chosen symbol, so they are rebuilt here.
        quirksNote?.stringValue = Self.quirksText
        applyQuirksState()
        applyAccessibilityState()
        applyMechanismState()
        applyUpdateState()
        // Opening Settings is the moment someone is wondering, so this is where
        // a check belongs. It is rate-limited to once a day inside.
        UpdateCheck.checkIfDue()
    }

    private func applyUpdateState() {
        switch UpdateCheck.state {
        case .unknown:
            updateNote?.stringValue = Settings.checksForUpdates
                ? "" : "Update checks are off."
            updateNote?.textColor = .secondaryLabelColor
            updateButton?.title = "Check Now"
        case .checking:
            updateNote?.stringValue = "Checking for a newer version\u{2026}"
            updateNote?.textColor = .secondaryLabelColor
            updateButton?.title = "Check Now"
        case .upToDate:
            updateNote?.stringValue = "This is the latest version."
            updateNote?.textColor = .secondaryLabelColor
            updateButton?.title = "Check Now"
        case let .available(version, _):
            updateNote?.stringValue = "Version \(version) is available."
            updateNote?.textColor = .controlAccentColor
            // Homebrew installs are updated by brew, which knows to quit the
            // running copy first. Dragging a new bundle over a cask install
            // leaves brew reporting it as outdated for ever, so this offers the
            // command rather than the download.
            updateButton?.title = UpdateCheck.isHomebrewInstall
                ? "Copy brew Command" : "Get \(version)\u{2026}"
            updateButton?.toolTip = UpdateCheck.isHomebrewInstall
                ? UpdateCheck.homebrewCommand : nil
        case let .failed(reason):
            updateNote?.stringValue = reason
            updateNote?.textColor = .secondaryLabelColor
            updateButton?.title = "Try Again"
        }
        fitWindow()
    }

    @objc private func updateChanged() {
        guard window != nil else { return }
        applyUpdateState()
    }

    @objc private func updateAction() {
        if UpdateCheck.availableVersion != nil {
            if UpdateCheck.isHomebrewInstall {
                UpdateCheck.copyHomebrewCommand()
                updateNote?.stringValue = "Copied \u{2014} run it in Terminal."
                updateNote?.toolTip = UpdateCheck.homebrewCommand
            } else {
                UpdateCheck.openReleasePage()
            }
            return
        }
        UpdateCheck.checkIfDue(force: true)
    }

    @objc private func openProjectPage() {
        NSWorkspace.shared.open(UpdateCheck.projectPage)
    }

    @objc private func toggleUpdateChecks(_ sender: NSButton) {
        Settings.checksForUpdates = sender.state == .on
        if sender.state == .on { UpdateCheck.checkIfDue(force: true) }
        applyUpdateState()
    }

    /// What Settings has to say about hiding right now: the text, and the button
    /// that does something about it. nil while there is nothing to report.
    private func mechanismState() -> (text: String, button: String)? {
        if Mechanism.current == .width {
            var text = "JustHide is using its older method: it makes room by widening a hidden "
                + "divider, which leaves a small gap in the menu bar and slides icons when they "
                + "hide. Hold \u{2318} and drag the icons you want hidden to the left of the "
                + "divider."
            if let advice = Mechanism.advice { text += "\n\n" + advice }
            return (text, "Use macOS Hiding")
        }
        if let failure = Mechanism.failure {
            return (Mechanism.sentence(failure)
                    + " JustHide has an older method that works without it, at the cost "
                    + "of a gap in the menu bar and icons that slide when they hide.",
                    "Use the Older Method")
        }
        return nil
    }

    /// Shown only when the permission is missing AND something the user has
    /// switched on needs it. Hiding itself works unpermitted, so a standing
    /// warning would be a nag -- but the clock option and the item shortcuts do
    /// not degrade without Accessibility, they do nothing whatever, and staying
    /// silent about that made both look broken.
    private func accessibilityWarning() -> String? {
        guard !AccessibilityAccess.isGranted else { return nil }
        var needed: [String] = []
        if Settings.clockClickThrough { needed.append("the clock option") }
        if !Settings.itemShortcuts.isEmpty { needed.append("menu bar shortcuts") }
        guard !needed.isEmpty else { return nil }

        let what = needed.joined(separator: " and ")
        let base = "Accessibility is off for JustHide, so \(what) cannot work. "
        // macOS ties the grant to the exact code signature, so installing a new
        // build drops it even though System Settings may still show JustHide
        // switched on. Saying so saves hunting for a fault that is not there.
        return base + (AccessibilityAccess.hasBeenAsked
            ? "Switch JustHide on under Privacy & Security, then restart it. Installing a "
              + "new build clears this permission, because macOS ties it to the app\u{2019}s "
              + "signature \u{2014} if JustHide is already switched on there, switch it off "
              + "and on again."
            : "Hiding still works; reading and pressing menu bar icons does not.")
    }

    private func applyAccessibilityState() {
        guard let warning = accessibilityWarning() else {
            accessRow?.isHidden = true
            accessNote?.stringValue = ""
            accessCollapsed?.isActive = true
            accessTop?.constant = 0
            fitWindow()
            return
        }
        accessNote?.stringValue = warning
        accessButton?.title = AccessibilityAccess.hasBeenAsked
            ? "Open System Settings" : "Allow\u{2026}"
        // Restarting only helps once the grant has been made, so it is offered
        // only on the second visit.
        accessRestartButton?.isHidden = !AccessibilityAccess.hasBeenAsked
        accessRow?.isHidden = false
        accessCollapsed?.isActive = false
        accessTop?.constant = 12
        fitWindow()
    }

    @objc private func allowAccessibility() {
        if AccessibilityAccess.hasBeenAsked {
            AccessibilityAccess.openSystemSettings()
        } else {
            AccessibilityAccess.request()
        }
        reload()
    }

    @objc private func restartForAccessibility() {
        AccessibilityAccess.restart()
    }

    @objc private func toggleQuirks() {
        Settings.showsGoodToKnow = quirksToggle?.state == .on
        applyQuirksState()
    }

    private func applyQuirksState() {
        let shown = Settings.showsGoodToKnow
        quirksToggle?.state = shown ? .on : .off
        quirksBox?.isHidden = !shown
        quirksCollapsed?.isActive = !shown
        fitWindow()
    }

    private func applyMechanismState() {
        guard let state = mechanismState() else {
            mechanismRow?.isHidden = true
            mechanismNote?.stringValue = ""
            mechanismCollapsed?.isActive = true
            mechanismTop?.constant = 0
            fitWindow()
            return
        }
        mechanismNote?.stringValue = state.text
        mechanismButton?.title = state.button
        // Switching back to concealment is pointless on a system that does not
        // have it: the button would restart the app into the same place.
        mechanismButton?.isEnabled = Mechanism.current == .width
            ? AssessmentMode.isAvailable : true
        mechanismRow?.isHidden = false
        mechanismCollapsed?.isActive = false
        mechanismTop?.constant = 12
        fitWindow()
    }

    /// Re-fits the window to its content, for a notice that appears or goes away
    /// while the window is open. Does nothing during build(), which sizes the
    /// window itself once everything is in place.
    private func fitWindow() {
        guard let window = window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let needed = content.fittingSize
        window.setContentSize(NSSize(width: Self.windowWidth, height: max(needed.height + 20, 480)))
    }

    @objc private func mechanismChanged() {
        guard window != nil else { return }
        applyMechanismState()
    }

    @objc private func switchMechanism() {
        Mechanism.use(Mechanism.current == .width ? .concealment : .width)
    }

    /// Re-reads the permission and the app list. Also on the \u{21BB} button by the
    /// list, for when an app has been opened since the window was.
    @objc private func recheck() {
        let granted = AccessibilityAccess.isGranted
        Log.controller.log("re-checking Accessibility: granted = \(granted)")
        reload()
        guard !granted, AccessibilityAccess.hasBeenAsked else { return }

        // A running process is not always told about a grant made after it
        // started, so "still not allowed" has two quite different meanings and
        // the only way to tell them apart is to start again.
        let alert = NSAlert()
        alert.messageText = "Accessibility still is not allowed"
        alert.informativeText = "If you have just switched JustHide on under Privacy & Security, "
            + "it needs to start again to pick that up.\n\nOtherwise, switch JustHide on in "
            + "System Settings first."
        alert.addButton(withTitle: "Restart JustHide")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: AccessibilityAccess.restart()
        case .alertSecondButtonReturn: AccessibilityAccess.openSystemSettings()
        default: break
        }
    }

    // MARK: - Hidden apps

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: showAddPicker()
        case 1: removeSelected()
        default: recheck()
        }
    }

    /// A sheet, not a pop-up menu: macOS 27 does not draw NSMenuItem images, and
    /// this list is much easier to read with each app's icon beside its name.
    /// See AppPicker.
    private func showAddPicker() {
        guard let window = window else { return }
        picker.present(over: window, excluding: Settings.listedBundleIDs) { [weak self] bundleIDs in
            // Added apps arrive hidden, because that is what adding one has
            // always meant and is still the common reason to. Untick the box to
            // keep an app visible and use it only for shortcuts.
            Settings.listedBundleIDs.formUnion(bundleIDs)
            Settings.hiddenBundleIDs.formUnion(bundleIDs)
            self?.reload()
        }
    }

    private func removeSelected() {
        guard let table = table else { return }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].bundleID : nil }
        guard !selected.isEmpty else { return }
        Settings.listedBundleIDs.subtract(selected)
        // A shortcut belongs to its row, so it goes with it -- but say so,
        // because a shortcut disappearing is not what was asked for.
        let dropped = Settings.pruneItemShortcuts()
        if !dropped.isEmpty {
            flash("Also removed "
                  + dropped.map { Settings.description(of: $0) }.joined(separator: " and ") + ".")
        }
        reload()
    }

    // MARK: - Options

    @objc private func toggleLogin() {
        let wanted = loginCheckbox?.state == .on
        if !LaunchAtLogin.set(wanted) {
            loginCheckbox?.state = wanted ? .off : .on
        }
        reload()
    }

    @objc private func toggleHover() {
        Settings.hoverToReveal = hoverCheckbox?.state == .on
    }

    @objc private func toggleClockClickThrough() {
        Settings.clockClickThrough = clockCheckbox?.state == .on
        // The "Good to know" note about the dead clock is only true while this
        // is off, so rebuild it.
        reload()
    }

    private func applyNowPlayingState() {
        let on = Settings.showsNowPlaying
        nowPlayingCheckbox?.state = on ? .on : .off
        nowPlayingStylePopUp?.isEnabled = on
        nowPlayingWhenPopUp?.isEnabled = on
        nowPlayingStylePopUp?.selectItem(at: Settings.nowPlayingStyle == .icon ? 0 : 1)
        nowPlayingWhenPopUp?.selectItem(at: Settings.nowPlayingAppearance == .whilePlaying ? 0 : 1)
        // Two players side by side is only possible while icons are revealed:
        // while anything is hidden, macOS hides its own.
        nowPlayingAppleNote?.stringValue = Settings.appleNowPlayingIsOn
            ? "Apple\u{2019}s own Now Playing is also switched on, so you will see both while "
              + "icons are revealed. Set Now Playing to \u{201C}Don\u{2019}t Show\u{201D} under Menu "
              + "Bar in System Settings to keep only this one."
            : "Apple\u{2019}s own Now Playing is switched off, so this is the only one."
    }

    /// Missing access outranks everything, because without it the item shows
    /// nothing at all; then the two-icons note, as for Now Playing.
    private func applyFocusState() {
        let on = Settings.showsFocus
        focusCheckbox?.state = on ? .on : .off
        focusWhenPopUp?.isEnabled = on
        focusWhenPopUp?.selectItem(at: Settings.focusAppearance == .whileOn ? 0 : 1)
        let readable = FocusStore.read() != .unreadable
        focusStatusNote?.textColor = on && !readable ? .systemOrange : .secondaryLabelColor
        if !readable {
            focusStatusNote?.stringValue = "JustHide does not have Full Disk Access yet, so it cannot "
                + "read which Focus is on" + (on ? " and the Focus icon stays away." : ".")
            focusStatusButton?.title = "Open Full Disk Access\u{2026}"
        } else if Settings.appleFocusIsOn {
            focusStatusNote?.stringValue = "Apple\u{2019}s own Focus icon is also switched on, so you "
                + "will see both while icons are revealed. Set Focus to \u{201C}Don\u{2019}t "
                + "Show\u{201D} under Menu Bar in System Settings to keep only this one."
            focusStatusButton?.title = "Open Menu Bar Settings\u{2026}"
        } else {
            focusStatusNote?.stringValue = "Apple\u{2019}s own Focus icon is switched off, so this "
                + "is the only one."
            focusStatusButton?.title = "Open Menu Bar Settings\u{2026}"
        }
    }

    @objc private func toggleFocus() {
        Settings.showsFocus = focusCheckbox?.state == .on
        reload()
    }

    @objc private func changeFocusWhen() {
        guard let raw = focusWhenPopUp?.selectedItem?.representedObject as? String,
              let when = Settings.FocusAppearance(rawValue: raw) else { return }
        Settings.focusAppearance = when
    }

    @objc private func focusStatusAction() {
        if FocusStore.read() == .unreadable {
            FocusStore.openFullDiskAccess()
        } else {
            openMenuBarSettings()
        }
    }

    @objc private func toggleNowPlaying() {
        Settings.showsNowPlaying = nowPlayingCheckbox?.state == .on
        reload()
    }

    @objc private func changeNowPlayingStyle() {
        guard let raw = nowPlayingStylePopUp?.selectedItem?.representedObject as? String,
              let style = Settings.NowPlayingStyle(rawValue: raw) else { return }
        Settings.nowPlayingStyle = style
    }

    @objc private func changeNowPlayingWhen() {
        guard let raw = nowPlayingWhenPopUp?.selectedItem?.representedObject as? String,
              let when = Settings.NowPlayingAppearance(rawValue: raw) else { return }
        Settings.nowPlayingAppearance = when
    }

    @objc private func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func changeGlyph() {
        guard let raw = glyphPopUp?.selectedItem?.representedObject as? String,
              let glyph = Settings.Glyph(rawValue: raw) else { return }
        Settings.glyph = glyph
        reload()
    }

    @objc private func changeAutoHide() {
        guard let seconds = autoHidePopUp?.selectedItem?.representedObject as? Double else { return }
        Settings.autoHideDelay = seconds
    }

    // MARK: - Shortcut recording

    @objc private func recordShortcut() {
        guard !recordingShortcut else { return stopRecording() }
        recordingShortcut = true
        // Our own shortcuts have to stand down, or Carbon fires the one being
        // reassigned instead of letting the recorder see the keys.
        GlobalHotkey.shared.suspendForRecording()
        shortcutButton?.title = "Press keys\u{2026}"
        // Local monitor: only while this window has focus, so recording cannot
        // swallow keystrokes meant for anything else.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            defer { self.stopRecording() }
            if event.keyCode == UInt16(kVK_Escape) {
                Settings.hotkey = nil
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else {
                NSSound.beep()   // a shortcut with no modifier would eat a normal key
                return nil
            }
            let shortcut = Settings.Shortcut(keyCode: Int(event.keyCode),
                                             modifierFlags: modifiers.rawValue)
            // The other direction of the same check the item rows make: taking
            // a combination an item already owns would leave that one dead.
            guard !Settings.itemShortcuts.values.contains(shortcut) else {
                NSSound.beep()
                self.flash("\(Settings.description(of: shortcut)) already opens a menu bar icon.")
                return nil
            }
            Settings.hotkey = shortcut
            return nil
        }
    }

    private func stopRecording() {
        recordingShortcut = false
        GlobalHotkey.shared.resumeAfterRecording()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        shortcutButton?.title = Settings.hotkeyDescription
        reload()
    }

    /// Recording for one row of the list. Same shape as the show/hide recorder
    /// above, but the row it belongs to has to be remembered, and a combination
    /// already spoken for has to be refused: Carbon simply fails to register a
    /// duplicate, which would look like a shortcut that does nothing.
    @objc private func recordItemShortcut(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let target = MenuBarItemTarget(storageKey: key)
        let clickedTheOneRecording = recordingTarget == target
        if recordingShortcut { stopRecording() }
        stopItemRecording()
        // Clicking the button that is already listening cancels, rather than
        // leaving no way out but pressing a key.
        guard !clickedTheOneRecording else { return }

        recordingTarget = target
        GlobalHotkey.shared.suspendForRecording()
        reload()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                Settings.itemShortcuts[target] = nil
                self.stopItemRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else {
                NSSound.beep()   // a shortcut with no modifier would eat a normal key
                self.stopItemRecording()
                return nil
            }
            let shortcut = Settings.Shortcut(keyCode: Int(event.keyCode),
                                             modifierFlags: modifiers.rawValue)
            guard !GlobalHotkey.shared.isTaken(shortcut, excluding: target) else {
                NSSound.beep()
                self.flash("\(Settings.description(of: shortcut)) is already used by JustHide.")
                self.stopItemRecording()
                return nil
            }
            Settings.itemShortcuts[target] = shortcut
            self.stopItemRecording()
            return nil
        }
    }

    private func stopItemRecording() {
        recordingTarget = nil
        GlobalHotkey.shared.resumeAfterRecording()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        reload()
    }

    /// A short-lived message in the note under the list. Cheaper than an alert
    /// for something the user can simply try again.
    private func flash(_ message: String) {
        guard let note = perAppNote else { return }
        flashToken += 1
        let token = flashToken
        note.stringValue = message
        note.textColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.flashToken == token else { return }
            note.stringValue = Self.perAppNoteText
            note.textColor = .secondaryLabelColor
        }
    }
}

// MARK: - Table

extension PreferencesWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "key": return shortcutCell(for: entry)
        case "hidden": return hiddenCell(for: entry)
        default: return nameCell(for: entry, row: row)
        }
    }

    /// Only whole apps can be selected: "\u{2212}" removes an app from the
    /// hidden list, and there is no such thing as removing one of its icons.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) ? !rows[row].isChild : false
    }

    private func nameCell(for entry: ListRow, row: Int) -> NSView {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: entry.name)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)

        if entry.isChild {
            // Indented, no icon: every icon here belongs to the app named above,
            // so repeating its icon would say nothing and read as a second app.
            text.textColor = .secondaryLabelColor
            if entry.isStale {
                text.stringValue = "\u{26A0} \(entry.name)"
                text.textColor = .systemOrange
                text.toolTip = "This icon is not in the menu bar under that name any more, so "
                    + "the shortcut cannot open it. Remove it, or set it again on the right row."
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 42),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            ])
            return cell
        }

        let icon = NSImageView(image: MenuBarApps.icon(for: entry.bundleID) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        ])

        guard entry.isExpandable else {
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20),
            ])
            return cell
        }

        let triangle = NSButton(title: "", target: self, action: #selector(toggleExpansion(_:)))
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.onOff)
        triangle.state = expandedBundleIDs.contains(entry.bundleID) ? .on : .off
        triangle.tag = row
        triangle.translatesAutoresizingMaskIntoConstraints = false
        triangle.toolTip = "\(entry.children.count) icons"
        cell.addSubview(triangle)
        NSLayoutConstraint.activate([
            triangle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            triangle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: triangle.trailingAnchor, constant: 2),
        ])
        return cell
    }

    /// Hiding is per app, so only an app row carries the tick box; the icon
    /// rows beneath it have nothing to say about it.
    private func hiddenCell(for entry: ListRow) -> NSView {
        let cell = NSTableCellView()
        guard !entry.isChild else { return cell }
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleHidden(_:)))
        box.state = Settings.hiddenBundleIDs.contains(entry.bundleID) ? .on : .off
        box.identifier = NSUserInterfaceItemIdentifier(entry.bundleID)
        box.toolTip = "Hide every icon this app puts in the menu bar."
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        var hidden = Settings.hiddenBundleIDs
        if sender.state == .on { hidden.insert(bundleID) } else { hidden.remove(bundleID) }
        Settings.hiddenBundleIDs = hidden
        reload()
    }

    private func shortcutCell(for entry: ListRow) -> NSView {
        let cell = NSTableCellView()

        guard let target = entry.target else {
            // Two different reasons, and the difference matters to whoever is
            // looking: an app row that has icons of its own to bind, or an icon
            // its app never named.
            let dash = NSTextField(labelWithString: "\u{2014}")
            dash.translatesAutoresizingMaskIntoConstraints = false
            dash.textColor = .tertiaryLabelColor
            dash.alignment = .right
            dash.toolTip = entry.isChild
                ? "\(entry.name) is not named by its app, so a shortcut cannot tell it "
                  + "from the app\u{2019}s other icons."
                : "Open this app to give one of its icons a shortcut."
            cell.addSubview(dash)
            NSLayoutConstraint.activate([
                dash.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                dash.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let existing = Settings.itemShortcuts[target]
        let button = NSButton(title: "", target: self, action: #selector(recordItemShortcut(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(target.storageKey)

        let refused = GlobalHotkey.shared.rejected.contains(target)
        if recordingTarget == target {
            button.title = "Press keys\u{2026}"
        } else if let existing = existing {
            // Marked rather than silently broken: macOS gives a shortcut to
            // whoever asked first, so one that another app already owns will
            // never reach us however it looks here.
            button.title = refused ? "\u{26A0} \(Settings.description(of: existing))"
                                   : Settings.description(of: existing)
        } else {
            button.title = "Set\u{2026}"
        }
        button.toolTip = shortcutTooltip(for: entry, refused: refused)

        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])

        // Escape while recording clears a shortcut too, but nobody would guess
        // that, so a set shortcut gets something to click. Not while recording:
        // the row is asking for keys, and removing what is being replaced is
        // one button too many.
        guard existing != nil, recordingTarget != target else {
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor,
                                             constant: -4).isActive = true
            return cell
        }
        let clear = NSButton(title: "", target: self, action: #selector(clearItemShortcut(_:)))
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill",
                              accessibilityDescription: "Remove this shortcut")
        clear.isBordered = false
        clear.controlSize = .small
        clear.contentTintColor = .secondaryLabelColor
        clear.toolTip = "Remove this shortcut"
        clear.identifier = NSUserInterfaceItemIdentifier(target.storageKey)
        clear.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(clear)
        NSLayoutConstraint.activate([
            clear.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            clear.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 16),
            button.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -4),
        ])
        return cell
    }

    private func shortcutTooltip(for entry: ListRow, refused: Bool) -> String {
        if refused {
            return "Another app already uses this combination, so macOS will not give it "
                + "to JustHide. Choose a different one."
        }
        if !MenuBarItemCatalogue.isRunning(entry.bundleID) {
            return "\(MenuBarApps.displayName(for: entry.bundleID)) is not running, so this "
                + "shortcut has nothing to open until it is."
        }
        return "Click, then press the keys. Escape clears it."
    }

    @objc private func clearShortcut() {
        if recordingShortcut { stopRecording() }
        Settings.hotkey = nil
        reload()
    }

    @objc private func clearItemShortcut(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        var shortcuts = Settings.itemShortcuts
        shortcuts[MenuBarItemTarget(storageKey: key)] = nil
        Settings.itemShortcuts = shortcuts
        reload()
    }

    @objc private func toggleExpansion(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let bundleID = rows[sender.tag].bundleID
        if expandedBundleIDs.contains(bundleID) {
            expandedBundleIDs.remove(bundleID)
        } else {
            expandedBundleIDs.insert(bundleID)
        }
        reload()
    }
}
