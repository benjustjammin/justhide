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

    /// How many spacers this run needs, ignoring what has been registered
    /// before. Every spacer costs ~16pt of visible bar even at zero length -- a
    /// status window carries its own padding -- so creating surplus ones leaves
    /// an obvious gap between the divider and the chevron. Hence: ask for
    /// exactly what the push needs, using last run's measured length when we
    /// have it.
    ///
    /// They must all exist before the divider (creation order is bar order), so
    /// this cannot wait for this run's calibration. On a first run it falls back
    /// to a deliberately pessimistic fraction of the narrowest region, which
    /// over-creates slightly; from the second run it is exact.
    static var estimatedSpacerCount: Int {
        let assumedPerItem = rememberedPerItemLength ?? (narrowestStatusRegion * 0.75)
        guard assumedPerItem > 0 else { return 2 }
        return max(1, spacersNeeded(perItem: assumedPerItem))
    }

    // MARK: - The spacer pool
    //
    // Item NAMES have to be stable, and the count above is not: calibration
    // writes a measured length on the first collapse, so the second launch on
    // the same displays can want a different number of spacers than the first.
    // That matters because macOS places a status item it has never seen before
    // at the FAR LEFT, wherever it was created in the order -- so a spacer whose
    // name appears for the first time on a later launch lands left of the
    // divider, inside the hidden section, where its width does no pushing. The
    // effect is silent: the bar collapses, the push falls short, icons leak.
    //
    // So the pool has a high-water mark per display arrangement. Asking for
    // FEWER spacers than the mark is safe -- those names have slots already.
    // Asking for MORE means new names, which can only be placed correctly by
    // re-registering the whole group under a new generation of names, which
    // costs the user one cmd-drag of their icons past the divider. Growth is
    // therefore deliberate, recorded, and applied at the next launch.

    private static let spacerPoolKey = "spacerPoolByDisplays"

    /// How many spacer names exist for this arrangement, and which generation of
    /// names the group is using. Pinned the first time an arrangement is seen.
    static var spacerPool: (highWater: Int, generation: Int) {
        let store = UserDefaults.standard.dictionary(forKey: spacerPoolKey) ?? [:]
        // Read through NSNumber rather than casting to [String: Int]: a value
        // typed in from the shell arrives as a string, and a failed cast here
        // would look like an arrangement never seen before and quietly re-pin
        // it. This key is worth setting by hand while testing.
        if let entry = store[displayFingerprint] as? [String: Any] {
            let number = { (key: String) in (entry[key] as? NSNumber)?.intValue
                            ?? Int(entry[key] as? String ?? "") }
            if let highWater = number("highWater"), highWater > 0 {
                return (highWater, number("generation") ?? 0)
            }
        }
        let pinned = (highWater: estimatedSpacerCount, generation: 0)
        write(pool: pinned)
        return pinned
    }

    /// The number to actually create: what this run wants, capped at the names
    /// that already have slots.
    static var spacerCountNeeded: Int {
        min(estimatedSpacerCount, spacerPool.highWater)
    }

    /// Records that the push needs more spacers than the pool holds, under a new
    /// generation of names. True if anything changed, which is the caller's cue
    /// to tell the user what the next launch will look like.
    @discardableResult
    static func widenSpacerPool(to needed: Int) -> Bool {
        let pool = spacerPool
        guard needed > pool.highWater else { return false }
        write(pool: (highWater: needed, generation: pool.generation + 1))
        return true
    }

    /// Starts the group's names again from scratch, which is the only way to fix
    /// items that have ended up in the wrong order: with no saved slots between
    /// them, macOS places them by creation order (see WidthController).
    static func bumpItemGeneration() {
        let pool = spacerPool
        write(pool: (highWater: pool.highWater, generation: pool.generation + 1))
    }

    private static func write(pool: (highWater: Int, generation: Int)) {
        var store = UserDefaults.standard.dictionary(forKey: spacerPoolKey) ?? [:]
        store[displayFingerprint] = ["highWater": pool.highWater, "generation": pool.generation]
        UserDefaults.standard.set(store, forKey: spacerPoolKey)
    }

    /// Appended to every one of JustHide's own status item names in width mode.
    /// Empty for the first generation, so an existing install keeps the slots it
    /// has.
    static var itemNameSuffix: String {
        let generation = spacerPool.generation
        return generation == 0 ? "" : "_g\(generation)"
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
