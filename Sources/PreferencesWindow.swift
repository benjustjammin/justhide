//
//  PreferencesWindow.swift
//  JustHide
//
//  One window, built in code, laid out like System Settings: a sidebar of
//  topics under headings, each a page of grouped rows with the controls on the
//  right. No storyboard to keep in sync.
//

import Cocoa
import Carbon.HIToolbox

final class PreferencesWindow: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindow()

    private var window: NSWindow?
    private var table: NSTableView?
    private var loginCheckbox: NSSwitch?
    private var loginTitle: NSTextField?
    private var hoverCheckbox: NSSwitch?
    private var newAppsCheckbox: NSSwitch?
    private var clockCheckbox: NSSwitch?
    private var clockNote: NSTextField?
    private var switchesCheckbox: NSSwitch?
    private var switchesNote: NSTextField?
    private var glyphPopUp: NSPopUpButton?
    private var nowPlayingCheckbox: NSSwitch?
    private var nowPlayingSourcePopUp: NSPopUpButton?
    private var nowPlayingNote: NSTextField?
    private var nowPlayingStylePopUp: NSPopUpButton?
    private var nowPlayingWhenPopUp: NSPopUpButton?
    private var nowPlayingAppleNote: NSTextField?
    private var focusCheckbox: NSSwitch?
    private var focusWhenPopUp: NSPopUpButton?
    private var focusStatusNote: NSTextField?
    private var focusStatusButton: NSButton?
    private var timeMachineCheckbox: NSSwitch?
    private var timeMachineWhenPopUp: NSPopUpButton?
    private var autoHidePopUp: NSPopUpButton?
    private var shortcutButton: NSButton?
    private var shortcutClear: NSButton?
    private var quirksNote: NSTextField?
    private var accessRow: NSStackView?
    private var accessNote: NSTextField?
    private var accessButton: NSButton?
    private var accessRestartButton: NSButton?
    private var mechanismRow: NSStackView?
    private var mechanismNote: NSTextField?
    private var mechanismButton: NSButton?
    private var updateNote: NSTextField?
    private var updateButton: NSButton?
    private var updatesCheckbox: NSSwitch?
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

    /// The pages, laid out like System Settings: a sidebar of topics under
    /// headings, each topic a scrolling page of grouped rows. One long window
    /// had grown to two columns and past the height of a laptop screen; split
    /// by topic, every page fits and each setting has an obvious home.
    enum Pane: String, CaseIterable {
        case apps, behaviour, nowPlaying, focus, timeMachine, general, about

        var title: String {
            switch self {
            case .apps: return "Menu Bar Apps"
            case .behaviour: return "Behaviour"
            case .nowPlaying: return "Now Playing"
            case .focus: return "Focus"
            case .timeMachine: return "Time Machine"
            case .general: return "General"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .apps: return "menubar.rectangle"
            case .behaviour: return "eye.slash"
            case .nowPlaying: return "music.note"
            case .focus: return "moon.fill"
            case .timeMachine: return "clock.arrow.circlepath"
            case .general: return "gearshape"
            case .about: return "info.circle"
            }
        }

        var color: NSColor {
            switch self {
            case .apps: return .systemBlue
            case .behaviour: return .systemIndigo
            case .nowPlaying: return .systemPink
            case .focus: return .systemPurple
            case .timeMachine: return .systemGreen
            case .general: return .systemGray
            case .about: return .systemGray
            }
        }
    }

    static let sidebarSections: [(heading: String, panes: [Pane])] = [
        ("Hiding", [.apps, .behaviour]),
        ("Extra Icons", [.nowPlaying, .focus, .timeMachine]),
        ("JustHide", [.general, .about]),
    ]

    private static let sidebarWidth: CGFloat = 210
    private static let paneWidth: CGFloat = 600
    /// A page's margins, and so the width of everything on it.
    private static let pageMargin: CGFloat = 24
    private static var groupWidth: CGFloat { paneWidth - 2 * pageMargin }
    /// Inside a group's padding: what a row's text has to fit in.
    private static var rowWidth: CGFloat { groupWidth - 24 }

    private var sidebar: SettingsSidebar?
    private var detail: NSView?
    private var pages: [Pane: NSView] = [:]
    private var currentPane: Pane = Pane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "")
        ?? .apps

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: Self.sidebarWidth + Self.paneWidth, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "JustHide Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        // An empty unified toolbar gives the tall title bar System Settings has,
        // with the page's name in it.
        window.toolbar = NSToolbar(identifier: "JustHideSettings")
        window.toolbarStyle = .unified

        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameActive),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)

        // ---- About: icon, name, version, updates
        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = label("JustHide", size: 22, bold: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let subtitle = label("Tidies your menu bar. Version \(version).", secondary: true)

        let updateNote = label("", secondary: true)
        updateNote.maximumNumberOfLines = 0
        updateNote.alignment = .center
        updateNote.preferredMaxLayoutWidth = Self.rowWidth
        self.updateNote = updateNote
        let updateButton = NSButton(title: "Check Now", target: self,
                                    action: #selector(updateAction))
        updateButton.bezelStyle = .rounded
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        self.updateButton = updateButton
        // A plain button rather than a link: a link in a window nobody expects
        // to be clickable is a guessing game, and this is the only outward
        // pointer in the app.
        let githubButton = NSButton(title: "GitHub", target: self, action: #selector(openProjectPage))
        githubButton.bezelStyle = .rounded
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        let updateButtons = NSStackView(views: [updateButton, githubButton])
        updateButtons.orientation = .horizontal
        updateButtons.spacing = 8
        let aboutHeader = NSStackView(views: [iconView, name, subtitle, updateNote, updateButtons])
        aboutHeader.orientation = .vertical
        aboutHeader.alignment = .centerX
        aboutHeader.spacing = 6
        aboutHeader.setCustomSpacing(10, after: iconView)
        aboutHeader.setCustomSpacing(10, after: updateNote)
        aboutHeader.translatesAutoresizingMaskIntoConstraints = false

        let updatesCheckbox = makeSwitch(#selector(toggleUpdateChecks))
        self.updatesCheckbox = updatesCheckbox

        // ---- Hidden apps
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
        // busy menu bar does not scroll straight away, capped so the page
        // stays readable. reload() sets the constant.
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 172)
        listHeight.isActive = true
        self.listHeight = listHeight
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let listButtons = NSSegmentedControl(labels: ["+", "\u{2212}", "\u{21BB}"],
                                             trackingMode: .momentary,
                                             target: self, action: #selector(addOrRemove(_:)))
        listButtons.segmentStyle = .smallSquare
        listButtons.translatesAutoresizingMaskIntoConstraints = false

        let perAppNote = label(Self.perAppNoteText, secondary: true)
        perAppNote.maximumNumberOfLines = 0
        perAppNote.preferredMaxLayoutWidth = Self.groupWidth - 110
        self.perAppNote = perAppNote
        let listFooter = NSStackView(views: [listButtons, perAppNote])
        listFooter.orientation = .horizontal
        listFooter.alignment = .top
        listFooter.spacing = 12
        listFooter.translatesAutoresizingMaskIntoConstraints = false

        let newAppsCheckbox = makeSwitch(#selector(toggleNewApps))
        self.newAppsCheckbox = newAppsCheckbox
        let newAppsNote = label("An app that has never had an icon in the bar is hidden when it "
                                + "first puts one up, and added to the list above, where unticking "
                                + "Hidden keeps it visible for good. Needs Accessibility, to see "
                                + "the icon.", secondary: true)
        newAppsNote.maximumNumberOfLines = 0

        // ---- Accessibility. Hidden unless something the user has actually
        // switched on needs the permission, so it is never a standing nag:
        // hiding itself works without it.
        let accessNote = label("", secondary: true)
        accessNote.textColor = .systemOrange
        accessNote.maximumNumberOfLines = 0
        accessNote.preferredMaxLayoutWidth = Self.groupWidth
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

        // ---- How hiding is going. Hidden while it is going fine, which is
        // nearly always -- but when it is not, this is the only place that
        // explains it and the only way to the other mechanism.
        let mechanismNote = label("", secondary: true)
        mechanismNote.textColor = .systemOrange
        mechanismNote.maximumNumberOfLines = 0
        mechanismNote.preferredMaxLayoutWidth = Self.groupWidth
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

        // ---- Behaviour
        let loginCheckbox = makeSwitch(#selector(toggleLogin))
        self.loginCheckbox = loginCheckbox
        let loginTitle = label("Open JustHide at login")
        self.loginTitle = loginTitle

        let hoverCheckbox = makeSwitch(#selector(toggleHover))
        self.hoverCheckbox = hoverCheckbox
        let hoverNote = label("Rest the pointer in the menu bar for half a second to show "
                              + "hidden icons.", secondary: true)
        hoverNote.maximumNumberOfLines = 0

        let clockCheckbox = makeSwitch(#selector(toggleClockClickThrough))
        self.clockCheckbox = clockCheckbox
        // The cost sits under the switch rather than only in "Good to know":
        // it is specific to this choice, so it belongs where the choice is made.
        let clockNote = label("macOS blocks Notification Center while icons are hidden. Clicking "
                              + "the clock unhides for a moment so it opens; closing it hides "
                              + "again. Your icons are back while Notification Center is open.",
                              secondary: true)
        clockNote.maximumNumberOfLines = 0
        self.clockNote = clockNote

        let switchesCheckbox = makeSwitch(#selector(toggleMenuBarSwitches))
        self.switchesCheckbox = switchesCheckbox
        let switchesNote = label("", secondary: true)
        switchesNote.maximumNumberOfLines = 0
        self.switchesNote = switchesNote

        let autoHidePopUp = NSPopUpButton()
        for option in Self.autoHideOptions {
            autoHidePopUp.addItem(withTitle: option.label)
            autoHidePopUp.lastItem?.representedObject = option.seconds
        }
        autoHidePopUp.target = self
        autoHidePopUp.action = #selector(changeAutoHide)
        self.autoHidePopUp = autoHidePopUp

        // ---- General
        let shortcutButton = NSButton(title: "None", target: self, action: #selector(recordShortcut))
        shortcutButton.bezelStyle = .rounded
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
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
        shortcutClear.widthAnchor.constraint(equalToConstant: 16).isActive = true
        self.shortcutClear = shortcutClear
        let shortcutControls = NSStackView(views: [shortcutButton, shortcutClear])
        shortcutControls.orientation = .horizontal
        shortcutControls.spacing = 6
        shortcutControls.translatesAutoresizingMaskIntoConstraints = false
        let shortcutNote = label("Shows or hides your icons from anywhere.", secondary: true)

        let glyphPopUp = NSPopUpButton()
        for glyph in Settings.Glyph.allCases {
            glyphPopUp.addItem(withTitle: glyph.label)
            glyphPopUp.lastItem?.representedObject = glyph.rawValue
        }
        glyphPopUp.target = self
        glyphPopUp.action = #selector(changeGlyph)
        self.glyphPopUp = glyphPopUp

        // ---- Now Playing
        let nowPlayingCheckbox = makeSwitch(#selector(toggleNowPlaying))
        self.nowPlayingCheckbox = nowPlayingCheckbox
        // Worded by applyNowPlayingState, because what it says about
        // permission depends on the source.
        let nowPlayingNote = label("", secondary: true)
        nowPlayingNote.maximumNumberOfLines = 0
        self.nowPlayingNote = nowPlayingNote

        let nowPlayingSourcePopUp = NSPopUpButton()
        for (title, source) in [("Any app, like macOS", Settings.NowPlayingSource.everything),
                                ("Apple Music only", Settings.NowPlayingSource.music)] {
            nowPlayingSourcePopUp.addItem(withTitle: title)
            nowPlayingSourcePopUp.lastItem?.representedObject = source.rawValue
        }
        nowPlayingSourcePopUp.target = self
        nowPlayingSourcePopUp.action = #selector(changeNowPlayingSource)
        self.nowPlayingSourcePopUp = nowPlayingSourcePopUp

        let nowPlayingStylePopUp = NSPopUpButton()
        for (title, style) in [("Icon", Settings.NowPlayingStyle.icon),
                               ("Icon and song", Settings.NowPlayingStyle.title)] {
            nowPlayingStylePopUp.addItem(withTitle: title)
            nowPlayingStylePopUp.lastItem?.representedObject = style.rawValue
        }
        nowPlayingStylePopUp.target = self
        nowPlayingStylePopUp.action = #selector(changeNowPlayingStyle)
        self.nowPlayingStylePopUp = nowPlayingStylePopUp

        let nowPlayingWhenPopUp = NSPopUpButton()
        for (title, when) in [("While playing or paused", Settings.NowPlayingAppearance.whilePlaying),
                              ("Always", Settings.NowPlayingAppearance.always)] {
            nowPlayingWhenPopUp.addItem(withTitle: title)
            nowPlayingWhenPopUp.lastItem?.representedObject = when.rawValue
        }
        nowPlayingWhenPopUp.target = self
        nowPlayingWhenPopUp.action = #selector(changeNowPlayingWhen)
        self.nowPlayingWhenPopUp = nowPlayingWhenPopUp

        // Apple's own is the user's setting, so this says how it is and opens
        // the page rather than changing it (see Settings.appleNowPlayingIsOn).
        let nowPlayingAppleNote = label("", secondary: true)
        nowPlayingAppleNote.maximumNumberOfLines = 0
        self.nowPlayingAppleNote = nowPlayingAppleNote
        let nowPlayingAppleButton = NSButton(title: "Open Menu Bar Settings\u{2026}", target: self,
                                             action: #selector(openMenuBarSettings))
        nowPlayingAppleButton.bezelStyle = .rounded
        nowPlayingAppleButton.translatesAutoresizingMaskIntoConstraints = false

        // ---- Focus. Built like Now Playing, with one status line and one
        // button saying what, if anything, still needs doing.
        let focusCheckbox = makeSwitch(#selector(toggleFocus))
        self.focusCheckbox = focusCheckbox
        let focusNote = label("Unlike Apple\u{2019}s, it stays while icons are hidden, with each "
                              + "Focus\u{2019}s own symbol. Click it to switch Focus. Listing your "
                              + "Focuses needs Full Disk Access, which JustHide uses only to read "
                              + "that list; switching goes through one shortcut, \u{201C}JustHide "
                              + "Focus\u{201D}, added to Shortcuts once \u{2014} the only way macOS "
                              + "lets an app do it.", secondary: true)
        focusNote.maximumNumberOfLines = 0

        let focusWhenPopUp = NSPopUpButton()
        for (title, when) in [("While a Focus is on", Settings.FocusAppearance.whileOn),
                              ("Always", Settings.FocusAppearance.always)] {
            focusWhenPopUp.addItem(withTitle: title)
            focusWhenPopUp.lastItem?.representedObject = when.rawValue
        }
        focusWhenPopUp.target = self
        focusWhenPopUp.action = #selector(changeFocusWhen)
        self.focusWhenPopUp = focusWhenPopUp

        let focusStatusNote = label("", secondary: true)
        focusStatusNote.maximumNumberOfLines = 0
        self.focusStatusNote = focusStatusNote
        let focusStatusButton = NSButton(title: "", target: self, action: #selector(focusStatusClicked))
        focusStatusButton.bezelStyle = .rounded
        focusStatusButton.translatesAutoresizingMaskIntoConstraints = false
        self.focusStatusButton = focusStatusButton

        // ---- Time Machine. Short: there is no Apple twin to warn about,
        // because turning this on switches Apple's off.
        let timeMachineCheckbox = makeSwitch(#selector(toggleTimeMachine))
        self.timeMachineCheckbox = timeMachineCheckbox
        let timeMachineNote = label("macOS will not hide Apple\u{2019}s. This switches it off and shows "
                                    + "one that can: backup status, Back Up Now and Browse Backups. "
                                    + "Turning this off puts Apple\u{2019}s back.", secondary: true)
        timeMachineNote.maximumNumberOfLines = 0
        let timeMachineWhenPopUp = NSPopUpButton()
        for (title, when) in [("Only while icons are shown", Settings.TimeMachineAppearance.withHidden),
                              ("Always", Settings.TimeMachineAppearance.always)] {
            timeMachineWhenPopUp.addItem(withTitle: title)
            timeMachineWhenPopUp.lastItem?.representedObject = when.rawValue
        }
        timeMachineWhenPopUp.target = self
        timeMachineWhenPopUp.action = #selector(changeTimeMachineWhen)
        self.timeMachineWhenPopUp = timeMachineWhenPopUp

        // ---- Good to know: reference material, so it lives on About rather
        // than in the way of the settings.
        let quirks = label(Self.quirksText, secondary: true)
        quirks.maximumNumberOfLines = 0
        quirks.preferredMaxLayoutWidth = Self.rowWidth
        quirksNote = quirks

        // ---- The pages
        pages[.apps] = page([
            accessRow,
            header("Apps with menu bar icons"),
            group([scroll], padded: false),
            listFooter,
            group([row("Hide new menu bar apps automatically", note: newAppsNote,
                       control: newAppsCheckbox)]),
        ])
        pages[.behaviour] = page([
            mechanismRow,
            group([
                row("Hide again after", control: autoHidePopUp),
                row("Reveal on hover in the menu bar", note: hoverNote, control: hoverCheckbox),
            ]),
            header("macOS\u{2019}s own icons"),
            group([
                row("Keep the camera button and Live Activities", note: switchesNote,
                    control: switchesCheckbox),
                row("Clock opens Notification Center", note: clockNote, control: clockCheckbox),
            ]),
        ])
        pages[.nowPlaying] = page([
            group([
                row("Show Now Playing", note: nowPlayingNote, control: nowPlayingCheckbox),
                row("Follow", control: nowPlayingSourcePopUp),
                row("In the menu bar", control: nowPlayingStylePopUp),
                row("Show it", control: nowPlayingWhenPopUp),
            ]),
            group([row(note: nowPlayingAppleNote, control: nowPlayingAppleButton)]),
        ])
        pages[.focus] = page([
            group([
                row("Show the current Focus", note: focusNote, control: focusCheckbox),
                row("Show it", control: focusWhenPopUp),
            ]),
            group([row(note: focusStatusNote, control: focusStatusButton)]),
        ])
        pages[.timeMachine] = page([
            group([
                row("Use JustHide\u{2019}s Time Machine icon", note: timeMachineNote,
                    control: timeMachineCheckbox),
                row("Show it", control: timeMachineWhenPopUp),
            ]),
        ])
        pages[.general] = page([
            group([
                row(title: loginTitle, control: loginCheckbox),
                row("Keyboard shortcut", note: shortcutNote, control: shortcutControls,
                    controlWidth: 172),
                row("Menu bar symbol", control: glyphPopUp),
            ]),
        ])
        pages[.about] = page([
            aboutHeader,
            group([row("Check GitHub for new versions",
                       note: label("Once a day, and nothing about you is sent.", secondary: true),
                       control: updatesCheckbox)]),
            header("Good to know"),
            group([padded(quirks)]),
        ])

        // ---- Sidebar and the page beside it
        let sidebar = SettingsSidebar(sections: Self.sidebarSections)
        sidebar.onSelect = { [weak self] pane in self?.select(pane) }
        self.sidebar = sidebar
        let sidebarController = NSViewController()
        sidebarController.view = sidebar.view
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth

        let detail = NSView()
        self.detail = detail
        let detailController = NSViewController()
        detailController.view = detail
        detail.widthAnchor.constraint(equalToConstant: Self.paneWidth).isActive = true
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailController))
        window.contentViewController = split

        applyAccessibilityState()
        applyMechanismState()
        applyUpdateState()

        NotificationCenter.default.addObserver(self, selector: #selector(mechanismChanged),
                                               name: .justHideMechanismChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateChanged),
                                               name: .justHideUpdateChanged, object: nil)

        // Fixed width, as System Settings is; the height is the user's, and
        // each page scrolls when it needs more.
        let height = min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        window.setContentSize(NSSize(width: Self.sidebarWidth + Self.paneWidth, height: height))
        window.contentMinSize = NSSize(width: Self.sidebarWidth + Self.paneWidth, height: 420)
        window.contentMaxSize = NSSize(width: Self.sidebarWidth + Self.paneWidth, height: 4000)

        self.window = window
        select(currentPane)
    }

    /// Shows one page, from the sidebar or from code.
    func select(_ pane: Pane) {
        currentPane = pane
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        sidebar?.select(pane)
        window?.title = pane.title
        guard let detail = detail, let page = pages[pane] else { return }
        detail.subviews.forEach { $0.removeFromSuperview() }
        detail.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: detail.topAnchor),
            page.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
        ])
    }

    // MARK: - Form pieces

    private func makeSwitch(_ action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        return toggle
    }

    /// A page: its views stacked from the top, scrolling when they run long.
    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 10, left: Self.pageMargin, bottom: 24, right: Self.pageMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where !(view is NSTextField) {
            view.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true
        }
        // A header sits close to the group it names.
        for (index, view) in views.enumerated() where view is NSTextField && index + 1 < views.count {
            stack.setCustomSpacing(6, after: view)
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    /// The small heading over a group.
    private func header(_ text: String) -> NSTextField {
        let field = label(text, bold: true)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    /// A rounded box of rows with hairlines between them, as in System Settings.
    private func group(_ rows: [NSView], padded: Bool = true) -> NSView {
        let box = GroupBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
                stack.setCustomSpacing(0, after: line)
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        box.addSubview(stack)
        let inset: CGFloat = padded ? 0 : 1
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
        ])
        return box
    }

    /// One setting: its name, an optional note under it, the control on the right.
    private func row(_ title: String? = nil, title titleField: NSTextField? = nil,
                     note: NSTextField? = nil, control: NSView?,
                     controlWidth: CGFloat? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        var texts: [NSView] = []
        if let field = titleField ?? title.map({ label($0) }) { texts.append(field) }
        if let note = note { texts.append(note) }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)

        // The row is as tall as its text or its control, whichever needs more:
        // both keep a margin for certain, the text's exact margin gives way.
        let snugTop = text.topAnchor.constraint(equalTo: row.topAnchor, constant: 10)
        let snugBottom = text.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10)
        snugTop.priority = .defaultLow
        snugBottom.priority = .defaultLow
        var constraints = [
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            snugTop, snugBottom,
        ]
        var width = Self.rowWidth
        if let control = control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            let wanted: CGFloat = controlWidth
                ?? (control is NSPopUpButton ? 210 : control.fittingSize.width)
            if control is NSPopUpButton {
                constraints.append(control.widthAnchor.constraint(equalToConstant: wanted))
            }
            constraints += [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 7),
                control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -7),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            ]
            // A few points spare: a note wrapped a hair too wide is clipped,
            // not re-wrapped, and loses its last line.
            width -= wanted + 16 + 6
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor,
                                                              constant: -12))
        }
        note?.preferredMaxLayoutWidth = width
        titleField?.preferredMaxLayoutWidth = width
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// Anything that is not a setting, with a row's padding round it.
    private func padded(_ view: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            view.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
        ])
        return row
    }

    /// Written for someone who did not implement it: what is surprising, and why.
    private static var quirksText: String {
        // Kept tight on purpose: this sits in a column, and a wall of text is
        // one nobody reads.
        let switches = Settings.hidesWithMenuBarSwitches
        var notes = [
            "• Hiding works per app, not per icon \u{2014} an app with several icons hides "
            + "all of them together.",
            "• Position means nothing here: a hidden icon is not moved aside, it is not "
            + "drawn at all. macOS places each icon and remembers it per app, so one can "
            + "sit either side of the JustHide symbol. \u{2318}-drag to rearrange.",
            "• Right-click the JustHide symbol, or \u{2325}-click it, to open any hidden icon "
            + "from its menu without showing the rest.",
            "• A shortcut opens an icon\u{2019}s own menu in place without unhiding it; press "
            + "again to close. Needs Accessibility, and the app must be running.",
        ]
        if switches {
            notes.append("• Hidden apps are switched off under Menu Bar in System Settings while "
                         + "they are hidden, and back on when shown or when JustHide quits. If an "
                         + "app Control Center has not seen yet is hidden, JustHide hides it the "
                         + "usual way, and macOS\u{2019}s own icons go with it until it has.")
        } else {
            notes.append("• While anything is hidden, macOS also hides its own Now Playing and Focus "
                         + "icons. JustHide\u{2019}s own versions stay; to avoid seeing two of each while "
                         + "icons are revealed, set Apple\u{2019}s to \u{201C}Don\u{2019}t Show\u{201D} under "
                         + "Menu Bar in System Settings. JustHide\u{2019}s Focus switches modes through its "
                         + "\u{201C}JustHide Focus\u{201D} shortcut, so keep that in Shortcuts.")
        }
        if switches {
            // Nothing to say about the clock: no assertion, nothing blocked.
        } else if Settings.clockClickThrough {
            notes.append("• Clicking the clock unhides briefly so Notification Center opens, "
                         + "and hides again when you close it \u{2014} macOS will not open it "
                         + "while icons are hidden.")
        } else {
            notes.append("• While icons are hidden, clicking the clock will not open "
                         + "Notification Center. Swipe in from the right edge, or turn on the "
                         + "clock option in Behaviour.")
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
        // Rows plus the column headers.
        let wanted = min(max(rows.count, 6), 14) * 24 + 8 + 28
        if listHeight?.constant != CGFloat(wanted) {
            listHeight?.constant = CGFloat(wanted)
            fitWindow()
        }

        loginCheckbox?.state = LaunchAtLogin.isEnabled ? .on : .off
        loginTitle?.stringValue = LaunchAtLogin.needsApproval
            ? "Open JustHide at login (approve it in System Settings)"
            : "Open JustHide at login"
        hoverCheckbox?.state = Settings.hoverToReveal ? .on : .off
        clockCheckbox?.state = Settings.clockClickThrough ? .on : .off
        updatesCheckbox?.state = Settings.checksForUpdates ? .on : .off

        glyphPopUp?.selectItem(at: Settings.Glyph.allCases.firstIndex(of: Settings.glyph) ?? 0)
        applyNowPlayingState()
        timeMachineCheckbox?.state = Settings.showsTimeMachine ? .on : .off
        timeMachineWhenPopUp?.isEnabled = Settings.showsTimeMachine
        timeMachineWhenPopUp?.selectItem(at: Settings.timeMachineAppearance == .withHidden ? 0 : 1)
        newAppsCheckbox?.state = Settings.hidesNewApps ? .on : .off
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
        applySwitchesState()

        // The notes depend on the chosen symbol, so they are rebuilt here.
        quirksNote?.stringValue = Self.quirksText
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

    @objc private func toggleUpdateChecks() {
        let on = updatesCheckbox?.state == .on
        Settings.checksForUpdates = on
        if on { UpdateCheck.checkIfDue(force: true) }
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
        if Settings.hidesNewApps { needed.append("hiding new apps") }
        guard !needed.isEmpty else { return nil }

        let what = needed.count > 1
            ? needed.dropLast().joined(separator: ", ") + " and " + needed.last!
            : needed[0]
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
            return
        }
        accessNote?.stringValue = warning
        accessButton?.title = AccessibilityAccess.hasBeenAsked
            ? "Open System Settings" : "Allow\u{2026}"
        // Restarting only helps once the grant has been made, so it is offered
        // only on the second visit.
        accessRestartButton?.isHidden = !AccessibilityAccess.hasBeenAsked
        accessRow?.isHidden = false
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

    private func applyMechanismState() {
        guard let state = mechanismState() else {
            mechanismRow?.isHidden = true
            mechanismNote?.stringValue = ""
            return
        }
        mechanismNote?.stringValue = state.text
        mechanismButton?.title = state.button
        // Switching back to concealment is pointless on a system that does not
        // have it: the button would restart the app into the same place.
        mechanismButton?.isEnabled = Mechanism.current == .width
            ? AssessmentMode.isAvailable : true
        mechanismRow?.isHidden = false
    }

    /// Pages scroll and the window keeps the size it was given, so there is
    /// nothing to fit any more; kept so the many callers need not change.
    private func fitWindow() {}

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

    /// The cost, and any trouble, under the checkbox -- like the clock's.
    private func applySwitchesState() {
        let on = Settings.hidesWithMenuBarSwitches
        let available = Mechanism.current == .concealment
        switchesCheckbox?.state = on ? .on : .off
        switchesCheckbox?.isEnabled = available
        switchesCheckbox?.toolTip = available ? nil : "Not available while JustHide is using its older method."
        var text = "Hides apps by switching them off under Menu Bar in System Settings, so macOS "
            + "keeps its own icons: the camera button, Live Activities, Focus and Now Playing, and "
            + "the clock opens Notification Center. Apps slide out rather than vanish. Needs one "
            + "file picked, once."
        if on, let problem = MenuBarSwitches.problem {
            text = problem + " Hiding the usual way until then."
        }
        switchesNote?.stringValue = text
        switchesNote?.textColor = !available ? .tertiaryLabelColor
            : (on && MenuBarSwitches.problem != nil ? .systemRed : .secondaryLabelColor)
    }

    @objc private func toggleMenuBarSwitches() {
        if switchesCheckbox?.state == .on {
            guard MenuBarSwitches.isGranted || MenuBarSwitches.grant() else {
                switchesCheckbox?.state = .off
                return
            }
            Settings.hidesWithMenuBarSwitches = true
        } else {
            // The controller switches everything back on as it hands over to
            // the assertion; the grant is kept, so turning it on again does not
            // ask a second time.
            Settings.hidesWithMenuBarSwitches = false
        }
        reload()
    }

    private func applyNowPlayingState() {
        let on = Settings.showsNowPlaying
        nowPlayingCheckbox?.state = on ? .on : .off
        nowPlayingSourcePopUp?.isEnabled = on
        nowPlayingStylePopUp?.isEnabled = on
        nowPlayingWhenPopUp?.isEnabled = on
        let source = Settings.nowPlayingSource
        nowPlayingSourcePopUp?.selectItem(at: source == .everything ? 0 : 1)
        let permission = source == .everything
            ? "Needs no permission; a Music favourite asks once to control Music."
            : "The controls ask once for permission to control Music."
        nowPlayingNote?.stringValue = "Unlike Apple\u{2019}s, it stays while icons are hidden. Click it "
            + "for the player; with the song showing, the heart favourites a Music song. " + permission
            + (source == .everything ? NowPlayingMonitor.shared.problem.map { "\n" + $0 } ?? "" : "")
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

    /// One status line and one button, most pressing first: without Full
    /// Disk Access there is no list, without the shortcut no switching, and
    /// only then the two-icons note, as for Now Playing.
    private func applyFocusState() {
        let on = Settings.showsFocus
        focusCheckbox?.state = on ? .on : .off
        focusWhenPopUp?.isEnabled = on
        focusWhenPopUp?.selectItem(at: Settings.focusAppearance == .whileOn ? 0 : 1)
        applyFocusStatus()
        // `shortcuts list` takes a moment, so the line is redrawn when it answers.
        if on { FocusShortcut.refresh { [weak self] in self?.applyFocusStatus() } }
    }

    private enum FocusStatusAction { case fullDiskAccess, shortcut, menuBarSettings }
    private var focusStatusAction: FocusStatusAction = .menuBarSettings

    private func applyFocusStatus() {
        if Settings.showsFocus && !FocusModes.isReadable {
            focusStatusNote?.stringValue = "To list your Focuses, JustHide needs Full Disk Access. "
                + "Without it the menu shows only the Focus that is on."
            focusStatusButton?.title = "Open Full Disk Access\u{2026}"
            focusStatusAction = .fullDiskAccess
        } else if Settings.showsFocus && FocusShortcut.isInstalled == false {
            focusStatusNote?.stringValue = "To switch Focus, JustHide needs its shortcut in "
                + "Shortcuts. The first time it runs, choose Always Allow."
            focusStatusButton?.title = "Add Shortcut\u{2026}"
            focusStatusAction = .shortcut
        } else if Settings.appleFocusIsOn {
            focusStatusNote?.stringValue = "Apple\u{2019}s own Focus icon is also switched on, so you "
                + "will see both while icons are revealed. Set Focus to \u{201C}Don\u{2019}t "
                + "Show\u{201D} under Menu Bar in System Settings to keep only this one."
            focusStatusButton?.title = "Open Menu Bar Settings\u{2026}"
            focusStatusAction = .menuBarSettings
        } else {
            focusStatusNote?.stringValue = "Apple\u{2019}s own Focus icon is switched off, so this "
                + "is the only one."
            focusStatusButton?.title = "Open Menu Bar Settings\u{2026}"
            focusStatusAction = .menuBarSettings
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

    @objc private func focusStatusClicked() {
        switch focusStatusAction {
        case .fullDiskAccess: FocusModes.openFullDiskAccessSettings()
        case .shortcut: FocusShortcut.install()
        case .menuBarSettings: openMenuBarSettings()
        }
    }

    @objc private func toggleTimeMachine() {
        Settings.showsTimeMachine = timeMachineCheckbox?.state == .on
        reload()
    }

    @objc private func changeTimeMachineWhen() {
        guard let raw = timeMachineWhenPopUp?.selectedItem?.representedObject as? String,
              let when = Settings.TimeMachineAppearance(rawValue: raw) else { return }
        Settings.timeMachineAppearance = when
    }

    @objc private func toggleNewApps() {
        Settings.hidesNewApps = newAppsCheckbox?.state == .on
        reload()
    }

    @objc private func toggleNowPlaying() {
        Settings.showsNowPlaying = nowPlayingCheckbox?.state == .on
        reload()
    }

    @objc private func changeNowPlayingSource() {
        guard let raw = nowPlayingSourcePopUp?.selectedItem?.representedObject as? String,
              let source = Settings.NowPlayingSource(rawValue: raw) else { return }
        Settings.nowPlayingSource = source
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

// MARK: - Window furniture

/// So a page's stack starts at the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The rounded box System Settings puts each set of rows in. Its colours are
/// set in updateLayer, so they follow a switch between light and dark.
private final class GroupBox: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
    }
}

/// The sidebar: headings, and under each the pages it covers, each with a
/// coloured icon in the System Settings manner.
final class SettingsSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Entry {
        case heading(String)
        case pane(PreferencesWindow.Pane)
    }

    let view = NSScrollView()
    var onSelect: ((PreferencesWindow.Pane) -> Void)?

    private let entries: [Entry]
    private let table = NSTableView()
    /// Set while selecting from code, so that is not mistaken for a click.
    private var selecting = false

    init(sections: [(heading: String, panes: [PreferencesWindow.Pane])]) {
        entries = sections.flatMap { [Entry.heading($0.heading)] + $0.panes.map(Entry.pane) }
        super.init()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane")))
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        view.documentView = table
        view.drawsBackground = false
        view.hasVerticalScroller = false
    }

    func select(_ pane: PreferencesWindow.Pane) {
        guard let index = entries.firstIndex(where: {
            if case let .pane(candidate) = $0 { return candidate == pane }
            return false
        }) else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selecting = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .pane = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = entries[row] { return 26 }
        return 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        cell.textField = text

        switch entries[row] {
        case let .heading(title):
            text.stringValue = title
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            text.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
        case let .pane(pane):
            text.stringValue = pane.title
            let icon = NSImageView(image: Self.icon(symbol: pane.symbol, color: pane.color))
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            ])
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, entries.indices.contains(table.selectedRow),
              case let .pane(pane) = entries[table.selectedRow] else { return }
        onSelect?(pane)
    }

    /// A white symbol on a coloured rounded square.
    private static func icon(symbol: String, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
    }
}
