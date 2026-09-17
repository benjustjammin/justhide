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
    private var permissionNote: NSTextField?
    private var permissionButton: NSButton?
    private var recheckButton: NSButton?
    private var permissionTop: NSLayoutConstraint?
    private var permissionHeight: NSLayoutConstraint?
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

        // ---- Accessibility, which only the list above depends on. Collapsed to
        // nothing once it is granted: a permission the user has already given is
        // not worth a row of the window.
        let permissionNote = label(AccessibilityAccess.explanation, secondary: true)
        permissionNote.textColor = .systemOrange
        self.permissionNote = permissionNote
        let permissionButton = NSButton(title: "Allow\u{2026}", target: self,
                                        action: #selector(requestAccessibility))
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        self.permissionButton = permissionButton
        // Granting happens in System Settings, and nothing tells us when it has
        // been done -- so there is an explicit way to ask again, rather than the
        // user wondering whether the window has noticed.
        let recheckButton = NSButton(title: "Re-check", target: self, action: #selector(recheck))
        recheckButton.bezelStyle = .rounded
        recheckButton.controlSize = .small
        recheckButton.translatesAutoresizingMaskIntoConstraints = false
        self.recheckButton = recheckButton
        let permissionRow = NSStackView(views: [permissionNote, permissionButton, recheckButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        permissionRow.translatesAutoresizingMaskIntoConstraints = false

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

        for view in [iconView, name, subtitle, listLabel, scroll, listButtons, perAppNote,
                     permissionRow, optionsLabel,
                     loginCheckbox, hoverCheckbox, autoHideLabel, autoHidePopUp,
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

            listLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 18),
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

            permissionRow.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),
            permissionRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                                    constant: -margin),

            optionsLabel.topAnchor.constraint(equalTo: permissionRow.bottomAnchor, constant: 18),
            optionsLabel.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            loginCheckbox.topAnchor.constraint(equalTo: optionsLabel.bottomAnchor, constant: 8),
            loginCheckbox.leadingAnchor.constraint(equalTo: controlColumn, constant: margin),

            hoverCheckbox.topAnchor.constraint(equalTo: loginCheckbox.bottomAnchor, constant: 6),
            hoverCheckbox.leadingAnchor.constraint(equalTo: loginCheckbox.leadingAnchor),

            autoHideLabel.topAnchor.constraint(equalTo: hoverCheckbox.bottomAnchor, constant: 14),
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

        let permissionTop = permissionRow.topAnchor.constraint(equalTo: listButtons.bottomAnchor,
                                                               constant: 12)
        let permissionHeight = permissionRow.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([permissionTop, permissionHeight])
        self.permissionTop = permissionTop
        self.permissionHeight = permissionHeight
        applyPermissionState()

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
        if Settings.glyph.flips {
            notes.append("• You have chosen a symbol that flips. On the display your "
                         + "icons live on it is always right, but a second display "
                         + "redraws it one change late, so the arrow points the wrong "
                         + "way there. Choose a symbol without \"flips\" to avoid it.")
        } else {
            notes.append("• This symbol stays the same whether icons are hidden or "
                         + "shown, which is why it is correct on every display.")
        }
        notes.append("• Hiding uses a part of macOS 27 that Apple does not document. "
                     + "If an update ever breaks it, JustHide says so in its log and "
                     + "the older method is still available by launching with --width.")
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

        glyphPopUp?.selectItem(at: Settings.Glyph.allCases.firstIndex(of: Settings.glyph) ?? 0)
        if let index = Self.autoHideOptions.firstIndex(where: { $0.seconds == Settings.autoHideDelay }) {
            autoHidePopUp?.selectItem(at: index)
        }
        if !recordingShortcut {
            shortcutButton?.title = Settings.hotkeyDescription
        }
        // The notes depend on the chosen symbol, so they are rebuilt here.
        quirksNote?.stringValue = Self.quirksText
        applyPermissionState()
    }

    private func applyPermissionState() {
        let granted = AccessibilityAccess.isGranted
        permissionNote?.stringValue = AccessibilityAccess.explanation
        permissionNote?.isHidden = granted
        permissionButton?.isHidden = granted
        recheckButton?.isHidden = granted
        // A hidden view still holds its space under Auto Layout, so the row is
        // collapsed rather than merely hidden.
        permissionHeight?.constant = granted ? 0 : 22
        permissionTop?.constant = granted ? 0 : 12
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

    @objc private func requestAccessibility() {
        // The system shows its dialog at most once per process, so from the
        // second press on the only thing that can help is the Settings pane.
        // Do both: whichever is available wins.
        if !AccessibilityAccess.request() {
            AccessibilityAccess.openSystemSettings()
        }
        reload()
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
