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

import Cocoa

enum MenuBarApps {
    /// Owners we never offer to hide: the system's own, and ourselves.
    private static var excluded: Set<String> {
        ["com.apple.controlcenter", "com.apple.MenuBarAgent", "com.apple.systemuiserver",
         Bundle.main.bundleIdentifier ?? ""]
    }

    /// Apps with at least one icon in the menu bar right now.
    static func current() -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        var found: [(String, String)] = []

        if AXIsProcessTrusted() {
            for item in AXMenuBar.currentItems() {
                guard let app = NSRunningApplication(processIdentifier: item.ownerPID),
                      let bundleID = app.bundleIdentifier,
                      !excluded.contains(bundleID),
                      seen.insert(bundleID).inserted else { continue }
                found.append((app.localizedName ?? bundleID, bundleID))
            }
        }
        if found.isEmpty {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
                guard let bundleID = app.bundleIdentifier,
                      !excluded.contains(bundleID),
                      seen.insert(bundleID).inserted else { continue }
                found.append((app.localizedName ?? bundleID, bundleID))
            }
        }
        return found
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, bundleID: $0.1) }
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

    static func icon(for bundleID: String) -> NSImage? {
        let image: NSImage?
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            image = running.icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = nil
        }
        image?.size = NSSize(width: 16, height: 16)
        return image
    }
}
