//
//  HiddenIconsMenu.swift
//  JustHide
//
//  The hidden icons, listed in the chevron's menu, each opening in place.
//
//  Hidden Bar's most-wanted request (dwarvesf/hidden#225): on a notched Mac
//  there is often no room to reveal everything, so reach a hidden icon without
//  revealing. It rests on what the per-icon shortcuts found (see
//  MenuBarItemShortcuts): an Accessibility press opens an icon's own menu
//  while it is hidden, under the assertion and -- measured 2026-10-13 with
//  iStat switched off in System Settings -- under the switches too.
//
//  Built when the menu opens, from what each running hidden app exposes right
//  then, so it is never stale and needs no identity: the element itself is
//  pressed. Apps that are not running have nothing to open and are left out.
//

import Cocoa

enum HiddenIconsMenu {
    /// A menu item holds its target weakly, and each row here is its own
    /// target; the chevron's menu is let go as soon as it closes, so the rows
    /// are kept until the next menu replaces them.
    private static var retained: [NSMenuItem] = []

    /// The section for the top of the chevron's menu, separator included, or
    /// nothing when there is nothing hidden that is running.
    static func items(target: AnyObject, settingsAction: Selector) -> [NSMenuItem] {
        let running = NSWorkspace.shared.runningApplications
        let apps = Settings.hiddenBundleIDs.compactMap { bundleID -> NSRunningApplication? in
            running.first { $0.bundleIdentifier == bundleID && $0.processIdentifier > 0 }
        }.sorted {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
        }
        guard !apps.isEmpty else { return [] }

        var items: [NSMenuItem] = [NSMenuItem.sectionHeader(title: "Hidden Icons")]
        guard AXIsProcessTrusted() else {
            // Without the permission there is no reading or pressing anyone's
            // icons, so say so once rather than listing rows that do nothing.
            let ask = NSMenuItem(title: "Allow Accessibility to Open Hidden Icons\u{2026}",
                                 action: settingsAction, keyEquivalent: "")
            ask.target = target
            items.append(ask)
            items.append(.separator())
            return items
        }

        for app in apps {
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            let icons = MenuBarItemCatalogue.live(pid: app.processIdentifier, appName: name)
            guard !icons.isEmpty else { continue }
            let row = HiddenIconItem(title: name, app: app, element: icons.count == 1 ? icons[0].element : nil)
            row.attributedTitle = title(name, icon: MenuBarApps.icon(for: app.bundleIdentifier ?? ""))
            if icons.count > 1 {
                // Several icons: one submenu, each named as the app names it.
                let submenu = NSMenu()
                for (index, icon) in icons.enumerated() {
                    // An app that names none of them gets them numbered, left
                    // to right, rather than a column of identical rows.
                    let label = icon.label == name ? "\(name) \(index + 1)" : icon.label
                    let entry = HiddenIconItem(title: label, app: app, element: icon.element)
                    submenu.addItem(entry)
                }
                row.submenu = submenu
            }
            items.append(row)
        }
        guard items.count > 1 else { return [] }
        items.append(.separator())
        retained = items + items.compactMap(\.submenu).flatMap(\.items)
        return items
    }

    /// App icons through an attachment: macOS 27 does not draw NSMenuItem
    /// images (see AppPicker), but it does draw images inside the title.
    private static func title(_ text: String, icon: NSImage?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if let icon = icon {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return title
    }
}

/// One row that opens one icon.
private final class HiddenIconItem: NSMenuItem {
    private let app: NSRunningApplication
    private let element: AXUIElement?

    init(title: String, app: NSRunningApplication, element: AXUIElement?) {
        self.app = app
        self.element = element
        super.init(title: title, action: element == nil ? nil : #selector(open), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func open() {
        guard let element = element else { return }
        let app = self.app
        // After our own menu has finished closing: pressing while it is still
        // tracking would have the other app's menu open and shut at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MenuBarItemPress.toggle(element: element, pid: app.processIdentifier,
                                    named: app.bundleIdentifier ?? "?")
        }
    }
}
