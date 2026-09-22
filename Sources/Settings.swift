//
//  Settings.swift
//  JustHide
//
//  Everything the user can change, in one place.
//

import Cocoa

enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let hiddenBundleIDs = "hiddenBundleIDs"
        static let listedBundleIDs = "listedBundleIDs"
        static let glyph = "glyph"
        static let autoHideDelay = "autoHideDelay"
        static let didMigrateFromNook = "didMigrateFromNook"
        static let checksForUpdates = "checkForUpdates"
        static let latestSeenVersion = "latestSeenVersion"
    }

    // MARK: - Updates

    /// Whether to ask GitHub, once a day, if there is a newer version. On by
    /// default and switchable, because it is the only thing in JustHide that
    /// touches the network at all.
    static var checksForUpdates: Bool {
        get { defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.checksForUpdates)
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }

    /// The newest version the last check saw, so the offer survives a restart
    /// without asking again.
    static var latestSeenVersion: String? {
        get { defaults.string(forKey: Key.latestSeenVersion) }
        set { defaults.set(newValue, forKey: Key.latestSeenVersion) }
    }

    /// The app was called Nook while it was being figured out. Carry the one
    /// setting that matters across rather than making the user redo it.
    static func migrateIfNeeded() {
        guard !defaults.bool(forKey: Key.didMigrateFromNook) else { return }
        defaults.set(true, forKey: Key.didMigrateFromNook)
        guard hiddenBundleIDs.isEmpty,
              let old = UserDefaults(suiteName: "dev.nook.bar"),
              let carried = old.stringArray(forKey: Key.hiddenBundleIDs),
              !carried.isEmpty else { return }
        hiddenBundleIDs = Set(carried)
        Log.controller.log("carried \(carried.count) hidden app(s) over from the previous name")
    }

    // MARK: - Hidden apps

    /// Apps the list in Settings shows.
    ///
    /// Separate from `hiddenBundleIDs` since 2026-09-22, because the two stopped
    /// meaning the same thing: a shortcut opens an icon whether or not it is
    /// hidden, so an app can be worth listing purely to give its icons
    /// shortcuts. Vorssaint is the case that forced it -- readouts kept visible
    /// but wanted on keys. Hidden is a tick box on the row; being listed is what
    /// the + and - buttons control. Every hidden app is necessarily listed.
    static var listedBundleIDs: Set<String> {
        get {
            guard let stored = defaults.stringArray(forKey: Key.listedBundleIDs) else {
                // Upgrading: everything hidden was by definition in the old
                // list, and anything holding a shortcut belongs there too or its
                // shortcut would have nowhere to be shown.
                return hiddenBundleIDs.union(itemShortcuts.keys.map(\.bundleID))
            }
            return Set(stored).union(hiddenBundleIDs)
        }
        set {
            defaults.set(newValue.sorted(), forKey: Key.listedBundleIDs)
            // Nothing may be hidden without being listed, or it would be
            // concealed with no row anywhere saying so. Assigning hiddenBundleIDs
            // posts the change notification itself.
            if hiddenBundleIDs.subtracting(newValue).isEmpty {
                NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
            } else {
                hiddenBundleIDs = hiddenBundleIDs.intersection(newValue)
            }
        }
    }

    /// Bundle identifiers whose menu bar items are hidden.
    static var hiddenBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenBundleIDs) ?? []) }
        set {
            defaults.set(newValue.sorted(), forKey: Key.hiddenBundleIDs)
            // The same invariant from the other side: ticking Hidden on a row
            // that is somehow not listed should list it.
            let listed = Set(defaults.stringArray(forKey: Key.listedBundleIDs) ?? [])
            if !newValue.subtracting(listed).isEmpty {
                defaults.set(listed.union(newValue).sorted(), forKey: Key.listedBundleIDs)
            }
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }

    // MARK: - Appearance

    /// The menu bar glyph.
    ///
    /// Two families: a FIXED glyph that looks the same in both states, and a
    /// FLIPPING one that points one way when hidden and the other when shown.
    ///
    /// The flipping ones used to be a trap -- a second display showed the wrong
    /// direction -- which is why they are labelled. That was not the glyph's
    /// fault: while an assertion is held the secondary bar's copy of the item
    /// stops updating, so the glyph has to be drawn BEFORE concealment goes up
    /// (see AssertionController.conceal). With that order they are correct on
    /// every display, and the choice is now only a matter of taste.
    enum Glyph: String, CaseIterable {
        case chevronFlipping = "chevron.flipping"
        case doubleChevronFlipping = "doubleChevron.flipping"
        case chevron = "\u{2039}"          // ‹
        case doubleChevron = "\u{00AB}"    // «
        case ellipsis = "\u{22EF}"         // ⋯
        case dot = "\u{2022}"              // •
        case bars = "\u{2261}"             // ≡

        /// True if the symbol changes with state. Kept because the labels use
        /// it; no longer a warning about anything.
        var flips: Bool {
            self == .chevronFlipping || self == .doubleChevronFlipping
        }

        /// The character to show. `concealed` is ignored by the fixed glyphs.
        func symbol(concealed: Bool) -> String {
            switch self {
            case .chevronFlipping: return concealed ? "\u{2039}" : "\u{203A}"       // ‹ ›
            case .doubleChevronFlipping: return concealed ? "\u{00AB}" : "\u{00BB}" // « »
            default: return rawValue
            }
        }

        var label: String {
            switch self {
            case .chevronFlipping: return "Chevron, flips  \u{2039} \u{203A}"
            case .doubleChevronFlipping: return "Double chevron, flips  \u{00AB} \u{00BB}"
            case .chevron: return "Chevron  \u{2039}"
            case .doubleChevron: return "Double chevron  \u{00AB}"
            case .ellipsis: return "Ellipsis  \u{22EF}"
            case .dot: return "Dot  \u{2022}"
            case .bars: return "Bars  \u{2261}"
            }
        }
    }

    static var glyph: Glyph {
        get {
            guard let raw = defaults.string(forKey: Key.glyph),
                  let glyph = Glyph(rawValue: raw) else { return .chevron }
            return glyph
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.glyph)
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }

    // MARK: - Behaviour

    /// Seconds of no interaction before the icons hide themselves again.
    /// 0 disables it.
    static var autoHideDelay: TimeInterval {
        get { defaults.object(forKey: Key.autoHideDelay) as? Double ?? 15 }
        set {
            defaults.set(newValue, forKey: Key.autoHideDelay)
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let justHideSettingsChanged = Notification.Name("justHideSettingsChanged")

    /// Hiding started or stopped working, or JustHide changed mechanism. Kept
    /// apart from justHideSettingsChanged: nothing the user chose has changed,
    /// and the controllers must not treat it as a settings edit.
    static let justHideMechanismChanged = Notification.Name("justHideMechanismChanged")

    /// The update check learned something: it started, finished, or found a
    /// newer version.
    static let justHideUpdateChanged = Notification.Name("justHideUpdateChanged")

    /// Sent between processes: a second copy of JustHide asks the one already
    /// running to open Settings, instead of adding a second chevron to the bar.
    static let justHideShowSettings = Notification.Name("dev.justhide.app.showSettings")
}
