//
//  MenuBarSwitches.swift
//  JustHide
//
//  The second way to hide: the switches under System Settings -> Menu Bar ->
//  Allow in Menu Bar, flipped by JustHide instead of by hand.
//
//  Why bother when the assertion works: while ANY concealment assertion is
//  held, macOS also hides its own extras -- the green camera button (the one
//  with Video Effects in it), Focus, Now Playing -- and ignores clicks on the
//  clock. A switched-off app holds no assertion, so all of those stay. Measured
//  on 27.2 (26B5101f), 2026-10-13, with Photo Booth on: under the assertion the
//  camera button went and only the privacy dot stayed; with Vorssaint switched
//  off this way instead, the camera button stayed.
//
//  How the switch is reached, measured on the same build:
//    - Control Centre keeps the switches in its group container's preferences,
//      `trackedApplications`: a binary plist (not a keyed archive) alternating
//      `{bundle:{_0:id}}` and `{location:..., menuItemLocations:[...], isAllowed}`.
//    - An ordinary write is refused by cfprefsd and CF quietly edits the file
//      instead, which Control Centre never notices. Once the user has picked the
//      file in an open panel, cfprefsd accepts the write from us and Control
//      Centre acts on it: the icon starts going within 0.1s, gone in ~0.8s (the
//      bar animates), back in ~0.5s, in its own slot.
//    - The pick is kept as a security-scoped bookmark, which resolves on the
//      next launch with no panel (it reports stale; it still works, and it is
//      re-saved). This is how Thaw 3 does it (PickedFileAccess.swift).
//    - The container path needs its TRAILING SLASH, or cfprefsd treats it as a
//      different source.
//    - On 27.2 beta 26B5091g the switch did nothing visible even by hand, so
//      this is fragile across builds; the assertion remains the default.
//
//  Only switches JustHide turned off are ever turned back on: they are recorded
//  (Settings.switchedOffInMenuBar) before the write, so a crash or a quit in
//  the middle is put right on the next launch, and an app the user switched off
//  themselves is never touched.
//

import Cocoa

enum MenuBarSwitches {
    private static let domain = "group.com.apple.controlcenter" as CFString
    private static let key = "trackedApplications" as CFString
    private static let folder = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter/"
    private static var container: CFString { folder as CFString }
    static let file = folder + "Library/Preferences/group.com.apple.controlcenter.plist"

    // Private CoreFoundation, looked up defensively like the assertion: a
    // missing symbol means "unavailable", never a crash.
    private typealias CopyFn = @convention(c) (CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
    private typealias SetFn = @convention(c) (CFString, CFPropertyList?, CFString, CFString) -> Void
    private typealias SyncFn = @convention(c) (CFString, CFString) -> DarwinBoolean

    private static let functions: (copy: CopyFn, set: SetFn, sync: SyncFn)? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let copy = dlsym(handle, "_CFPreferencesCopyAppValueWithContainer"),
              let set = dlsym(handle, "_CFPreferencesSetAppValueWithContainer"),
              let sync = dlsym(handle, "_CFPreferencesAppSynchronizeWithContainer")
        else { return nil }
        return (unsafeBitCast(copy, to: CopyFn.self), unsafeBitCast(set, to: SetFn.self),
                unsafeBitCast(sync, to: SyncFn.self))
    }()

    /// Why the last attempt could not use the switches, for Settings to show.
    private(set) static var problem: String?

    // MARK: - Access

    private static var accessedURL: URL?

    static var isGranted: Bool { Settings.menuBarSwitchesBookmark != nil }

    /// Asks for the file, once. Returns whether access was granted.
    static func grant() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: file).deletingLastPathComponent()
        panel.message = "To switch apps off the way System Settings does, JustHide needs this one "
            + "file. Select \u{201C}group.com.apple.controlcenter.plist\u{201D} and click Allow."
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.resolvingSymlinksInPath().path == URL(fileURLWithPath: file).resolvingSymlinksInPath().path else {
            let alert = NSAlert()
            alert.messageText = "That is not the file JustHide needs"
            alert.informativeText = "Select \u{201C}group.com.apple.controlcenter.plist\u{201D} in the "
                + "folder the panel opens in."
            alert.runModal()
            return false
        }
        guard url.startAccessingSecurityScopedResource(),
              let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else {
            Log.controller.error("could not keep access to Control Centre's preferences")
            return false
        }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url
        Settings.menuBarSwitchesBookmark = bookmark
        problem = nil
        Log.controller.log("access to Control Centre's preferences granted")
        return true
    }

    /// Opened once and held for the life of the app: cfprefsd only accepts our
    /// writes while it is.
    private static func openAccess() -> Bool {
        if accessedURL != nil { return true }
        guard let bookmark = Settings.menuBarSwitchesBookmark else {
            problem = "JustHide has not been given the file it needs."
            return false
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else {
            problem = "JustHide lost access to the file it needs. Turn the option off and on to pick it again."
            Log.controller.error("Control Centre bookmark no longer resolves")
            return false
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil) {
            Settings.menuBarSwitchesBookmark = fresh
        }
        accessedURL = url
        return true
    }

    /// Forgets the grant, after putting everything back.
    static func revoke() {
        restoreAll()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        Settings.menuBarSwitchesBookmark = nil
    }

    // MARK: - Switching

    /// Switches off every app in `hidden` that Control Centre tracks and turns
    /// back on whatever JustHide switched off earlier and no longer should.
    /// Returns the hidden IDs that are now taken care of -- those Control
    /// Centre knows, whether switched off by us or already off -- or nil when
    /// the switches cannot be used at all. Writes only if something changes.
    @discardableResult
    static func apply(hiding hidden: Set<String>) -> Set<String>? {
        guard let functions = functions else {
            problem = "This version of macOS does not offer what this option needs."
            return nil
        }
        guard openAccess() else { return nil }
        guard let raw = functions.copy(key, domain, container)?.takeRetainedValue() as? Data,
              var items = (try? PropertyListSerialization.propertyList(from: raw, format: nil)) as? [Any]
        else {
            problem = "Could not read System Settings\u{2019} Menu Bar switches."
            Log.controller.error("could not read trackedApplications")
            return nil
        }

        var recorded = Settings.switchedOffInMenuBar
        var handled: Set<String> = []
        var changed: [String] = []
        for index in stride(from: 0, to: items.count - 1, by: 2) {
            guard let owner = bundleID(in: items[index]),
                  var entry = items[index + 1] as? [String: Any],
                  let allowed = entry["isAllowed"] as? Bool else { continue }
            // An app's icons can come from a helper with its own ID (iStat
            // Menus' are com.bjango.istatmenus.status), named in the locations.
            let ids = Set([owner] + ((entry["menuItemLocations"] as? [Any]) ?? []).compactMap(bundleID))
            let matches = ids.intersection(hidden)
            if !matches.isEmpty {
                handled.formUnion(matches)
                if allowed {
                    entry["isAllowed"] = false
                    recorded.insert(owner)
                    changed.append("\(owner) off")
                }
            } else if !allowed, recorded.contains(owner) {
                entry["isAllowed"] = true
                recorded.remove(owner)
                changed.append("\(owner) on")
            } else if allowed {
                // Switched back on by someone else: no longer ours to restore.
                recorded.remove(owner)
            }
            items[index + 1] = entry
        }

        guard !changed.isEmpty else {
            Settings.switchedOffInMenuBar = recorded
            problem = nil
            return handled
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
        else { return nil }
        // Recorded first: if we die between here and the write, the next launch
        // turns on something that was never off, which is harmless.
        Settings.switchedOffInMenuBar = Settings.switchedOffInMenuBar.union(recorded)
        functions.set(key, data as CFData, domain, container)
        let synced = functions.sync(domain, container).boolValue
        Settings.switchedOffInMenuBar = recorded
        problem = nil
        Log.controller.log("menu bar switches: \(changed.joined(separator: ", ")) (synced \(synced))")
        return handled
    }

    /// Turns back on everything JustHide switched off. For reveal, quit, and
    /// the next launch after a crash.
    static func restoreAll() {
        guard !Settings.switchedOffInMenuBar.isEmpty else { return }
        apply(hiding: [])
    }

    private static func bundleID(in value: Any) -> String? {
        let dictionary = value as? [String: Any]
        let bundle = (dictionary?["bundle"] ?? (dictionary?["location"] as? [String: Any])?["bundle"])
        return (bundle as? [String: Any])?["_0"] as? String
    }
}
