//
//  MenuBarApps.swift
//  JustHide
//
//  Which apps currently own menu bar icons, and how to describe one.
//
//  On macOS 27 items are not windows any more, so ownership is read through
//  Accessibility. Without that permission this falls back to listing apps that
//  could plausibly own an item, which is a longer list but never empty.
//
//  Accessibility is the only source of ownership there is, and it goes blind at
//  awkward moments: the permission is keyed on the code signature, so an ad-hoc
//  rebuild silently loses it, and an app that is plainly in the bar then vanishes
//  from the "add" list. So owners are remembered across launches and the ones
//  still running are offered too -- once an app has been seen owning an icon it
//  cannot fall out of the list.
//
//  (A concealed icon is NOT a reason to be missing here: measured on 27.0, an
//  item concealed by assessment mode is still reported under AXExtrasMenuBar,
//  frame and all, even one concealed from the moment it appeared.)
//

import Cocoa

enum MenuBarApps {
    private static let knownKey = "knownMenuBarApps"

    /// Owners we never offer to hide: the system's own, and ourselves.
    private static var excluded: Set<String> {
        ["com.apple.controlcenter", "com.apple.MenuBarAgent", "com.apple.systemuiserver",
         Bundle.main.bundleIdentifier ?? ""]
    }

    /// What the picker can offer, kept in two groups rather than one list, so it
    /// can say which apps are in the bar at this moment and which are only known
    /// to have been there before.
    struct Candidates {
        var inBarNow: [(name: String, bundleID: String)] = []
        var seenBefore: [(name: String, bundleID: String)] = []
        /// False means neither group is trustworthy: without the permission there
        /// is no way to tell who owns an icon, so `seenBefore` is every running app.
        var accessibilityGranted = true
    }

    static func candidates() -> Candidates {
        guard AXIsProcessTrusted() else {
            let running = Set(NSWorkspace.shared.runningApplications
                                .filter { $0.activationPolicy != .prohibited }
                                .compactMap(\.bundleIdentifier))
            return Candidates(seenBefore: named(running.subtracting(excluded)),
                              accessibilityGranted: false)
        }
        let inBar = owners().subtracting(excluded)
        remember(inBar)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let before = known.intersection(running).subtracting(inBar).subtracting(excluded)
        return Candidates(inBarNow: named(inBar), seenBefore: named(before))
    }

    /// Both groups in one list, for callers that do not care which is which.
    static func current() -> [(name: String, bundleID: String)] {
        let candidates = candidates()
        return named(Set((candidates.inBarNow + candidates.seenBefore).map(\.bundleID)))
    }

    private static func named(_ bundleIDs: Set<String>) -> [(name: String, bundleID: String)] {
        bundleIDs
            .filter(isPresentableApp)
            .map { (name: displayName(for: $0), bundleID: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app someone would recognise from their Applications folder, as opposed
    /// to one of the system's own processes. Without this the list is unusable
    /// with Accessibility off, when every running process is a candidate: forty
    /// rows of coreautha, PowerChime and loginwindow to find Clop in.
    ///
    /// Judged by where the bundle lives: an Applications folder, which is what
    /// "an app" means to the person reading the list. It sorts this Mac exactly.
    /// Every real menu bar app is under /Applications, including helpers nested
    /// inside one -- /Applications/iStat Menus.app/Contents/Resources/iStat Menus
    /// Menubar.app is how iStat's readouts appear -- while Finder, Siri,
    /// loginwindow, PowerChime and Control Center all live in
    /// /System/Library/CoreServices and are nobody's idea of an app to hide.
    private static func isPresentableApp(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        let path = url.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/", "/System/Applications/", "\(home)/Applications/"]
            .contains { path.hasPrefix($0) }
    }

    /// Bundle IDs owning a menu bar item right now, as far as Accessibility knows.
    private static func owners() -> Set<String> {
        var ids = Set<String>()
        for item in AXMenuBar.currentItems() {
            guard let app = NSRunningApplication(processIdentifier: item.ownerPID),
                  let bundleID = app.bundleIdentifier else { continue }
            ids.insert(bundleID)
        }
        return ids
    }

    /// Owners seen in the menu bar at some point, kept across launches.
    private static var known: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: knownKey) ?? [])
    }

    private static func remember(_ bundleIDs: Set<String>) {
        let wanted = known.union(bundleIDs.subtracting(excluded))
        guard wanted != known else { return }
        UserDefaults.standard.set(wanted.sorted(), forKey: knownKey)
    }

    /// A readable name for a bundle ID, whether or not the app is running. Falls
    /// back to the identifier so a hidden entry is never a blank row.
    static func displayName(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(for bundleID: String, size: CGFloat = 16) -> NSImage? {
        let source: NSImage?
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon {
            source = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            source = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            source = nil
        }
        // Copy before resizing. Both of those calls hand back a shared instance,
        // so setting `size` on it shrinks that app's icon everywhere else it is
        // drawn for the lifetime of the process. A copy shares the underlying
        // representations, so it still draws crisply on a Retina display.
        guard let sized = source?.copy() as? NSImage else { return nil }
        sized.size = NSSize(width: size, height: size)
        return sized
    }
}
