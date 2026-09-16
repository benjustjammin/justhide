//
//  MenuBarGeometry.swift
//  JustHide
//
//  Everything the hiding maths needs from the attached displays. Pure reads of
//  NSScreen, no assumed constants: the numbers that matter differ per machine,
//  per display arrangement and per notch.
//

import Cocoa

enum MenuBarGeometry {
    /// The push must clear the WIDEST bar, since status items are laid out on one
    /// display and mirrored onto the rest. A status region can never be wider
    /// than its screen, so this bounds what is needed.
    static var widestBarWidth: CGFloat {
        NSScreen.screens.map { $0.frame.width }.max() ?? 1728
    }

    /// A single item can never claim more than the NARROWEST status region: that
    /// is what the ejection cap is. On a notched display the region is the part
    /// right of the notch, which NSScreen reports directly; elsewhere the screen
    /// width is the only bound available.
    static var narrowestStatusRegion: CGFloat {
        NSScreen.screens
            .map { $0.auxiliaryTopRightArea?.width ?? $0.frame.width }
            .min() ?? widestBarWidth
    }

    /// Fingerprint of the current display arrangement, so a remembered
    /// calibration is only reused on the geometry it was measured on.
    static var displayFingerprint: String {
        NSScreen.screens
            .map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.origin.x)):\($0.backingScaleFactor)" }
            .sorted()
            .joined(separator: "|")
    }

    private static let rememberedLengthKey = "calibratedLengthByDisplays"

    /// What calibration measured last time on this exact arrangement, if anything.
    static var rememberedPerItemLength: CGFloat? {
        guard let store = UserDefaults.standard.dictionary(forKey: rememberedLengthKey),
              let value = store[displayFingerprint] as? Double, value > 0 else { return nil }
        return CGFloat(value)
    }

    static func remember(perItemLength: CGFloat) {
        var store = UserDefaults.standard.dictionary(forKey: rememberedLengthKey) ?? [:]
        store[displayFingerprint] = Double(perItemLength)
        UserDefaults.standard.set(store, forKey: rememberedLengthKey)
    }

    /// How many spacers to create. Every spacer costs ~16pt of visible bar even
    /// at zero length -- a status window carries its own padding -- so creating
    /// surplus ones leaves an obvious gap between the divider and the chevron.
    /// Hence: create exactly what the push needs, using last run's measured
    /// length when we have it.
    ///
    /// They must all exist before the divider (creation order is bar order), so
    /// this cannot wait for this run's calibration. On a first run it falls back
    /// to a deliberately pessimistic fraction of the narrowest region, which
    /// over-creates slightly; from the second run it is exact.
    static var spacerCountNeeded: Int {
        let assumedPerItem = rememberedPerItemLength ?? (narrowestStatusRegion * 0.75)
        guard assumedPerItem > 0 else { return 2 }
        return max(1, spacersNeeded(perItem: assumedPerItem))
    }

    /// How many spacers a given per-item length needs to reach the target push.
    /// The divider itself carries the first chunk.
    static func spacersNeeded(perItem: CGFloat) -> Int {
        guard perItem > 0 else { return 0 }
        let remaining = widestBarWidth - perItem
        guard remaining > 0 else { return 0 }
        return Int((remaining / perItem).rounded(.up))
    }

    /// True while the pointer is in any screen's menubar band. On a fullscreen
    /// space the band collapses to nothing and this reads false, which is
    /// intentional: no visible menu bar, nothing to protect.
    static var pointerIsInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }
}
