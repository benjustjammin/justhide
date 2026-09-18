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
    private var glyphPopUp: NSPopUpButton?
    private var autoHidePopUp: NSPopUpButton?
    private var shortcutButton: NSButton?
    private var quirksNote: NSTextField?
    private var mechanismRow: NSStackView?
    private var mechanismNote: NSTextField?
    private var mechanismButton: NSButton?
    private var mechanismTop: NSLayoutConstraint?
    private var mechanismCollapsed: NSLayoutConstraint?
    private var updateNote: NSTextField?
    private var updateButton: NSButton?
    private var updatesCheckbox: NSButton?
    private let picker = AppPicker()

    private var rows: [(name: String, bundleID: String)] = []
    /// While true the next keystroke is captured as the shortcut.
    private var recordingShortcut = false
    private var keyMonitor: Any?

    func show() {
        if window == nil { build() }
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
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
        let listLabel = label("Hide these apps' menu bar icons", bold: true)

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")))
        table.dataSource = self
        table.delegate = self
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let listButtons = NSSegmentedControl(labels: ["+", "\u{2212}", "\u{21BB}"],
                                             trackingMode: .momentary,
                                             target: self, action: #selector(addOrRemove(_:)))
        listButtons.segmentStyle = .smallSquare
        listButtons.translatesAutoresizingMaskIntoConstraints = false

        let perAppNote = label("Hiding applies to a whole app, not to one of its icons.",
                               secondary: true)

        // No Accessibility row. Hiding works without the permission -- it is only
        // needed to LIST what is in the bar right now -- so a standing orange
        // warning here was a nag for something that breaks nothing. The ask now
        // lives in the app picker, which is the one place it makes a difference,
        // and the list's third button re-reads it.

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

        let hoverCheckbox = NSButton(checkboxWithTitle: "Reveal when the pointer rests in the menu bar",
                                     target: self, action: #selector(toggleHover))
        hoverCheckbox.translatesAutoresizingMaskIntoConstraints = false
        self.hoverCheckbox = hoverCheckbox

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

        // ---- Quirks
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
        NSLayoutConstraint.activate([
            quirks.topAnchor.constraint(equalTo: quirksBox.topAnchor, constant: 10),
            quirks.leadingAnchor.constraint(equalTo: quirksBox.leadingAnchor, constant: 12),
            quirks.trailingAnchor.constraint(equalTo: quirksBox.trailingAnchor, constant: -12),
            quirks.bottomAnchor.constraint(equalTo: quirksBox.bottomAnchor, constant: -10),
        ])

        for view in [iconView, name, subtitle, updateRow, listLabel, scroll, listButtons, perAppNote,
                     mechanismRow, optionsLabel,
                     loginCheckbox, hoverCheckbox, updatesCheckbox, autoHideLabel, autoHidePopUp,
                     shortcutLabel, shortcutButton, glyphLabel, glyphPopUp,
                     quirksLabel, quirksBox] {
            content.addSubview(view)
        }

        let margin: CGFloat = 20
        let controlColumn = content.leadingAnchor
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

            // Whichever of the icon and the header text runs lower decides where
            // the list starts, so a two-line update note cannot collide with it.
            listLabel.topAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor,
                                           constant: 18),
            listLabel.topAnchor.constraint(greaterThanOrEqualTo: updateRow.bottomAnchor,
                                           constant: 14),
            listLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            scroll.topAnchor.constraint(equalTo: listLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            scroll.heightAnchor.constraint(equalToConstant: 132),

            listButtons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.widthAnchor.constraint(equalToConstant: 108),

            perAppNote.centerYAnchor.constraint(equalTo: listButtons.centerYAnchor),
            perAppNote.leadingAnchor.constraint(equalTo: listButtons.trailingAnchor, constant: 10),

            mechanismRow.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            mechanismRow.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                   constant: -margin),

            optionsLabel.topAnchor.constraint(equalTo: mechanismRow.bottomAnchor, constant: 18),
            optionsLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            loginCheckbox.topAnchor.constraint(equalTo: optionsLabel.bottomAnchor, constant: 8),
            loginCheckbox.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            hoverCheckbox.topAnchor.constraint(equalTo: loginCheckbox.bottomAnchor, constant: 6),
            hoverCheckbox.leadingAnchor.constraint(equalTo: loginCheckbox.leadingAnchor),

            updatesCheckbox.topAnchor.constraint(equalTo: hoverCheckbox.bottomAnchor, constant: 6),
            updatesCheckbox.leadingAnchor.constraint(equalTo: loginCheckbox.leadingAnchor),

            autoHideLabel.topAnchor.constraint(equalTo: updatesCheckbox.bottomAnchor, constant: 14),
            autoHideLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            autoHidePopUp.centerYAnchor.constraint(equalTo: autoHideLabel.centerYAnchor),
            autoHidePopUp.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 170),
            autoHidePopUp.widthAnchor.constraint(equalToConstant: 180),

            shortcutLabel.topAnchor.constraint(equalTo: autoHideLabel.bottomAnchor, constant: 14),
            shortcutLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            shortcutButton.centerYAnchor.constraint(equalTo: shortcutLabel.centerYAnchor),
            shortcutButton.leadingAnchor.constraint(equalTo: autoHidePopUp.leadingAnchor),
            shortcutButton.widthAnchor.constraint(equalToConstant: 180),

            glyphLabel.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 14),
            glyphLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            glyphPopUp.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
            glyphPopUp.leadingAnchor.constraint(equalTo: autoHidePopUp.leadingAnchor),
            glyphPopUp.widthAnchor.constraint(equalToConstant: 180),

            quirksLabel.topAnchor.constraint(equalTo: glyphLabel.bottomAnchor, constant: 18),
            quirksLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            quirksBox.topAnchor.constraint(equalTo: quirksLabel.bottomAnchor, constant: 6),
            quirksBox.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            quirksBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            quirksBox.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -margin),
        ])

        // The mechanism row's height is its content, not a constant: the note
        // wraps to however many lines it needs. Only the collapsed state is a
        // fixed height, so that constraint is the one switched on and off.
        let mechanismTop = mechanismRow.topAnchor.constraint(equalTo: listButtons.bottomAnchor,
                                                             constant: 12)
        mechanismTop.isActive = true
        self.mechanismTop = mechanismTop
        self.mechanismCollapsed = mechanismRow.heightAnchor.constraint(equalToConstant: 0)

        let snug = listLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 18)
        snug.priority = .defaultLow
        snug.isActive = true

        applyMechanismState()
        applyUpdateState()

        NotificationCenter.default.addObserver(self, selector: #selector(mechanismChanged),
                                               name: .justHideMechanismChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateChanged),
                                               name: .justHideUpdateChanged, object: nil)

        // Fit the window to the content rather than to a guessed height.
        content.layoutSubtreeIfNeeded()
        let needed = content.fittingSize
        window.setContentSize(NSSize(width: 520, height: max(needed.height + margin, 560)))

        self.window = window
    }

    /// Written for someone who did not implement it: what is surprising, and why.
    private static var quirksText: String {
        var notes = [
            "• Hiding works per app, not per icon. An app with several icons hides "
            + "all of them together.",
            "• Position means nothing here: this list decides what is hidden, and a "
            + "hidden icon is not moved to one side, it is not drawn at all. macOS "
            + "decides where each icon sits, and remembers it per app, so an icon can "
            + "sit either side of the JustHide symbol. Hold \u{2318} and drag icons to "
            + "arrange them; that is remembered too.",
            "• While icons are hidden, clicking the clock will not open Notification "
            + "Center. Swipe from the right edge, or reveal first.",
        ]
        if Mechanism.current == .concealment {
            notes.append("• Hiding uses a part of macOS 27 that Apple does not document. If an "
                         + "update ever takes it away, JustHide says so on its symbol and offers "
                         + "you its older method, which needs nothing undocumented.")
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

    private func reload() {
        rows = Settings.hiddenBundleIDs
            .map { (name: MenuBarApps.displayName(for: $0), bundleID: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        table?.reloadData()

        loginCheckbox?.state = LaunchAtLogin.isEnabled ? .on : .off
        loginCheckbox?.title = LaunchAtLogin.needsApproval
            ? "Open JustHide at login (approve it in System Settings)"
            : "Open JustHide at login"
        hoverCheckbox?.state = Settings.hoverToReveal ? .on : .off
        updatesCheckbox?.state = Settings.checksForUpdates ? .on : .off

        glyphPopUp?.selectItem(at: Settings.Glyph.allCases.firstIndex(of: Settings.glyph) ?? 0)
        if let index = Self.autoHideOptions.firstIndex(where: { $0.seconds == Settings.autoHideDelay }) {
            autoHidePopUp?.selectItem(at: index)
        }
        if !recordingShortcut {
            shortcutButton?.title = Settings.hotkeyDescription
        }
        // Hover reveal is part of the concealment controller only; the width
        // mechanism has no cheap way to do it, so the box says so rather than
        // offering a switch that does nothing.
        hoverCheckbox?.isEnabled = Mechanism.current == .concealment
        hoverCheckbox?.toolTip = Mechanism.current == .concealment
            ? nil : "Not available while JustHide is using its older method."

        // The notes depend on the chosen symbol, so they are rebuilt here.
        quirksNote?.stringValue = Self.quirksText
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
        window.setContentSize(NSSize(width: 520, height: max(needed.height + 20, 560)))
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
        picker.present(over: window, excluding: Settings.hiddenBundleIDs) { [weak self] bundleIDs in
            Settings.hiddenBundleIDs.formUnion(bundleIDs)
            self?.reload()
        }
    }

    private func removeSelected() {
        guard let table = table else { return }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].bundleID : nil }
        guard !selected.isEmpty else { return }
        Settings.hiddenBundleIDs.subtract(selected)
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
            Settings.hotkey = Settings.Shortcut(keyCode: Int(event.keyCode),
                                                modifierFlags: modifiers.rawValue)
            return nil
        }
    }

    private func stopRecording() {
        recordingShortcut = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        shortcutButton?.title = Settings.hotkeyDescription
        reload()
    }
}

// MARK: - Table

extension PreferencesWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: MenuBarApps.icon(for: entry.bundleID) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: entry.name)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        ])
        return cell
    }
}
