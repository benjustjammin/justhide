//
//  CollapseCalibrator.swift
//  JustHide
//
//  Measuring the longest divider macOS 27 will actually lay out.
//
//  Asking for too much does not clamp, it EJECTS the item from the layout, and
//  an ejected item pushes nothing, so hiding fails silently. The cap moves with
//  the display and with how full the bar is, so it is binary searched.
//
//  Telling the two states apart, which took most of a day to get right:
//
//    The divider sits beside the chevron and can only grow AWAY from it, so
//    while it is laid out the gap between them does not change, however long it
//    gets. Ejected, its frame runs straight past the chevron and the gap tracks
//    the requested length.
//
//    The gap is NOT zero and must not be assumed so -- spacers legitimately sit
//    between the two -- so what matters is that it has not MOVED. The reference
//    has to be taken while COLLAPSED: measured while expanded it is ~115pt out,
//    because spacers squeezed out of a full bar are only placed once a collapse
//    frees up region, and every probe then reads as ejected.
//
//    Measured spread, reference -98pt: laid out 15-45pt of movement (28-671pt
//    requested), CLIPPED 214-445pt (737-968pt), ejected 947pt+ (975pt and up).
//    Clipped is a partial placement that does not hide reliably, so the test is
//    absolute rather than proportional -- a proportional test accepted 968pt.
//

import Cocoa

final class CollapseCalibrator {
    /// Two icon widths: covers status-window padding plus the measured drift,
    /// and sits far below what an ejection moves.
    private static let driftAllowance: CGFloat = 48
    /// Below this a result is a failed measurement, not a display that cannot
    /// hide: even a notch leaves several hundred points.
    private static let implausiblyShort: CGFloat = 100
    private static let maxAttempts = 3

    private var cached: CGFloat?
    private var isSearching = false
    private var attempts = 0

    func invalidate() {
        cached = nil
        attempts = 0
    }

    func honoredLength(divider: NSStatusItem,
                       chevron: NSStatusItem,
                       completion: @escaping (CGFloat?) -> Void) {
        if let cached = cached {
            completion(cached)
            return
        }
        guard !isSearching else { completion(nil); return }
        // Without backing windows nothing is measurable. Return without caching
        // so a later collapse tries again.
        guard divider.button?.window != nil, chevron.button?.window != nil else {
            completion(nil)
            return
        }
        isSearching = true
        measureReference(divider: divider, chevron: chevron) { [weak self] reference in
            guard let self = self, let reference = reference else {
                self?.isSearching = false
                completion(nil)
                return
            }
            self.search(divider: divider, chevron: chevron, reference: reference, completion: completion)
        }
    }

    private func gap(divider: NSStatusItem, chevron: NSStatusItem) -> CGFloat? {
        guard let dividerFrame = divider.button?.window?.frame,
              let chevronFrame = chevron.button?.window?.frame else { return nil }
        return dividerFrame.maxX - chevronFrame.minX
    }

    /// A hair above the open width: collapsed, but far too small to be ejected,
    /// which makes it a trustworthy zero point.
    private func measureReference(divider: NSStatusItem,
                                  chevron: NSStatusItem,
                                  completion: @escaping (CGFloat?) -> Void) {
        divider.length = JustHide.dividerExpandedLength + 8
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return completion(nil) }
            let reference = self.gap(divider: divider, chevron: chevron)
            Log.controller.log("reference gap \(reference.map { String(Int($0)) } ?? "nil")pt")
            completion(reference)
        }
    }

    private func search(divider: NSStatusItem,
                        chevron: NSStatusItem,
                        reference: CGFloat,
                        completion: @escaping (CGFloat?) -> Void) {
        var low = JustHide.dividerExpandedLength
        var high = max(500, min(MenuBarGeometry.widestBarWidth * 2, 10_000))
        var best = low
        var iterations = 0

        func probe() {
            guard iterations < 9, high - low > 8 else { return finish() }
            iterations += 1
            let mid = ((low + high) / 2).rounded()
            divider.length = mid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self else { return }
                let current = self.gap(divider: divider, chevron: chevron) ?? .greatestFiniteMagnitude
                let moved = abs(current - reference)
                let laidOut = moved <= Self.driftAllowance
                Log.controller.log("probe \(Int(mid))pt gap \(Int(current)) moved \(Int(moved)) -> \(laidOut ? "laid out" : "ejected")")
                if laidOut {
                    best = mid
                    low = mid
                } else {
                    high = mid
                }
                probe()
            }
        }

        func finish() {
            isSearching = false
            attempts += 1
            if best < Self.implausiblyShort, attempts < Self.maxAttempts {
                Log.controller.error("attempt \(self.attempts): nothing laid out (best \(Int(best))pt); will re-measure")
                divider.length = JustHide.dividerExpandedLength
                completion(nil)
                return
            }
            cached = best
            // Remembered so the next launch can size the spacer pool exactly,
            // instead of over-creating items that each cost visible bar space.
            MenuBarGeometry.remember(perItemLength: best)
            Log.controller.log("calibrated \(Int(best))pt")
            completion(best)
        }

        probe()
    }
}
