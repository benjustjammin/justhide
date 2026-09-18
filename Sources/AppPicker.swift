//
//  AppPicker.swift
//  JustHide
//
//  The "add an app to hide" list, as a sheet rather than a pop-up menu.
//
//  It was a menu until macOS 27 turned out not to draw NSMenuItem images at all.
//  Measured with a bare test app: an app icon at 16pt, the same at 18pt and a
//  plain SF Symbol, all on enabled items in a popped-up NSMenu, none of them
//  rendered. A table view draws them without complaint, which is what this is.
//
//  A table is the better shape for the job anyway: an app is easier to find by
//  icon, the two groups can be labelled, and without Accessibility the list is
//  every running app -- forty-odd rows, including agents nobody has heard of --
//  which needs searching and scrolling rather than a menu the height of the
//  screen.
//

import Cocoa

final class AppPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let name: String
        let bundleID: String
        /// Whether Accessibility can see this app owning an icon right now, as
        /// opposed to it being remembered from before.
        let inBarNow: Bool
    }

    private var panel: NSPanel?
    private var table: NSTableView?
    private var addButton: NSButton?
    private var all: [Row] = []
    private var shown: [Row] = []
    private var onAdd: (([String]) -> Void)?

    /// Shown as a sheet on the Settings window, so it cannot be lost behind it.
    func present(over window: NSWindow, excluding hidden: Set<String>,
                 onAdd: @escaping ([String]) -> Void) {
        self.onAdd = onAdd

        let candidates = MenuBarApps.candidates()
        all = (candidates.inBarNow.map { Row(name: $0.name, bundleID: $0.bundleID, inBarNow: true) }
               + candidates.seenBefore.map { Row(name: $0.name, bundleID: $0.bundleID, inBarNow: false) })
            .filter { !hidden.contains($0.bundleID) }
        shown = all

        let panel = build(accessibilityGranted: candidates.accessibilityGranted)
        self.panel = panel
        table?.reloadData()
        updateAddButton()
        window.beginSheet(panel)
    }

    private func build(accessibilityGranted: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Add Apps to Hide"
        let content = NSView()
        panel.contentView = content

        let title = NSTextField(labelWithString: "Choose apps whose menu bar icons should hide")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.translatesAutoresizingMaskIntoConstraints = false

        // Stated plainly rather than warned about: the permission changes what
        // this list can sort, and nothing else. Hiding works without it, so the
        // orange it used to be was out of proportion.
        let note = NSTextField(labelWithString: accessibilityGranted
            ? "Apps in your menu bar now are listed first."
            : "Every running app is listed. Allow Accessibility and JustHide can put the ones "
                + "in your menu bar first.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 380
        note.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.placeholderString = "Search"
        search.target = self
        search.action = #selector(filter(_:))
        search.sendsWholeSearchString = false
        search.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 28
        table.style = .inset
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(add)
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let other = NSButton(title: "Other App\u{2026}", target: self, action: #selector(addFromPanel))
        other.bezelStyle = .rounded
        other.translatesAutoresizingMaskIntoConstraints = false

        // Shown only while the permission is missing, so it disappears once it
        // has been given rather than sitting there for ever. It sits under the
        // note that explains it, in a stack view -- which collapses a hidden
        // view rather than leaving a gap where it would have been.
        let allow = NSButton(title: "Allow Accessibility\u{2026}", target: self,
                             action: #selector(requestAccessibility))
        allow.bezelStyle = .rounded
        allow.controlSize = .small
        allow.isHidden = accessibilityGranted
        allow.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSStackView(views: [note, allow])
        explanation.orientation = .vertical
        explanation.alignment = .leading
        explanation.spacing = 6
        explanation.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "Add", target: self, action: #selector(self.add))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"
        add.translatesAutoresizingMaskIntoConstraints = false
        addButton = add

        for view in [title, explanation, search, scroll, other, cancel, add] {
            content.addSubview(view)
        }

        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),

            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                  constant: -margin),

            search.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -12),

            other.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            other.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),

            add.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            add.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            cancel.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -10),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        return panel
    }

    // MARK: - Actions

    @objc private func filter(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        table?.reloadData()
        updateAddButton()
    }

    @objc private func add() {
        guard let table = table else { return }
        let picked = table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].bundleID : nil }
        guard !picked.isEmpty else { return }
        finish(with: picked)
    }

    @objc private func cancel() {
        finish(with: [])
    }

    /// The system shows its dialog at most once per process, so from the second
    /// press on the only thing that can help is the Settings pane. Try both.
    @objc private func requestAccessibility() {
        if !AccessibilityAccess.request() {
            AccessibilityAccess.openSystemSettings()
        }
    }

    /// The file picker, for an app that is not running and has never been seen:
    /// there is nothing to list it under, but its bundle still has an identifier.
    @objc private func addFromPanel() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.allowsMultipleSelection = true
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.prompt = "Add"
        guard open.runModal() == .OK else { return }
        let picked = open.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        finish(with: picked)
    }

    private func finish(with bundleIDs: [String]) {
        if let panel = panel {
            panel.sheetParent?.endSheet(panel)
        }
        panel = nil
        table = nil
        let onAdd = self.onAdd
        self.onAdd = nil
        if !bundleIDs.isEmpty { onAdd?(bundleIDs) }
    }

    private func updateAddButton() {
        addButton?.isEnabled = !(table?.selectedRowIndexes.isEmpty ?? true)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateAddButton() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        let cell = NSTableCellView()

        let icon = NSImageView(image: MenuBarApps.icon(for: entry.bundleID, size: 20) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: entry.name)
        name.translatesAutoresizingMaskIntoConstraints = false
        // The claim being made about this row, kept quiet and on the right: the
        // list is ordered by it anyway, this is for when one is looked at.
        let tag = NSTextField(labelWithString: entry.inBarNow ? "in your menu bar" : "seen before")
        tag.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tag.textColor = .tertiaryLabelColor
        tag.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, name, tag] { cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            tag.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            tag.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tag.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
