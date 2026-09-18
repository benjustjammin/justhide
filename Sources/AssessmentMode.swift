//
//  AssessmentMode.swift
//  JustHide
//
//  The real hiding mechanism on macOS 27: a private assessment-mode assertion.
//
//  macOS 27 ships an allowlist-based concealment facility (the one behind exam
//  "assessment mode"). Hold an assertion naming the bundle identifiers that may
//  show items, and MenuBarAgent conceals everything else. No layout tricks, so
//  none of the artifacts the width mechanism has: no dead space between items,
//  no icons sliding across a wide mirrored display, nothing to calibrate.
//
//      /System/Library/PrivateFrameworks/MenuBarClientCore.framework
//      MBAssessmentModeConfiguration -initWithAllowedSystemItems:allowedBundleIdentifiers:
//      MBAssessmentModeAssertion     -activateWithConfiguration:completionHandler:, -invalidate
//
//  Private API, so it is loaded defensively: every class and selector is checked
//  before use and the whole thing reports unavailable rather than trapping if a
//  future build moves it.
//
//  Found via jordanbaird/Ice#995, which adapted it from Thaw's PlatformRuntimeKit
//  by way of Barometer (both GPLv3). Known costs documented there and worth
//  repeating: while an assertion is live MenuBarAgent ignores clicks on its OWN
//  items (clock, battery, Wi-Fi), so those need intercepting and replaying with
//  concealment briefly lifted; and the allowlist is reportedly only honoured for
//  Developer ID-signed apps, meaning a locally-signed build conceals its own icon.
//

import Cocoa

enum AssessmentMode {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configureSelector =
        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector =
        NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    /// MenuBarAgent numbers its own system items 0 through 8 on macOS 27.0.
    /// Keeping all of them means the clock, Wi-Fi and battery stay put.
    private static let systemItems = (0...8).map { NSNumber(value: $0) } as NSArray

    private static let classes: (configuration: AnyClass, assertion: AnyClass)? = {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration"),
              let assertion = NSClassFromString("MBAssessmentModeAssertion"),
              configuration.instancesRespond(to: configureSelector),
              assertion.instancesRespond(to: activateSelector),
              assertion.instancesRespond(to: invalidateSelector)
        else { return nil }
        return (configuration, assertion)
    }()

    static var isAvailable: Bool {
        !CommandLine.arguments.contains("--simulate-unavailable") && classes != nil
    }

    /// Both of the failure paths are hard to reach on a working system -- that is
    /// the point of them -- so they can be asked for:
    ///   --simulate-unavailable   the framework is missing, as after an update
    ///   --simulate-failure       the assertion is refused
    private static var simulatesFailure: Bool {
        CommandLine.arguments.contains("--simulate-failure")
    }

    /// A live assertion. Holding it keeps the concealment up; dropping it reveals.
    final class Token {
        fileprivate let assertion: AnyObject
        fileprivate init(assertion: AnyObject) { self.assertion = assertion }
        func invalidate() {
            _ = assertion.perform(AssessmentMode.invalidateSelector)
        }
    }

    /// Everything running except the apps to hide. Concealment is expressed as an
    /// allowlist, so hiding is "permit all the others".
    ///
    /// This is a snapshot: an app that launches afterwards is not on the list and
    /// its icon is concealed even though nobody asked for it, so whoever holds the
    /// assertion has to keep it up to date (see AssertionController).
    static func allowlist(excluding hiddenBundleIDs: Set<String>) -> Set<String> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return running.subtracting(hiddenBundleIDs)
    }

    /// Activates an assertion permitting exactly `allowed`, concealing the rest.
    ///
    /// An allowlist entry is only honoured for an app running from a normal place.
    /// Measured on 27.0 with one ad-hoc signed test app: run from /private/tmp its
    /// icon was concealed by every assertion, its identifier on the list or not;
    /// the same bundle copied to /Applications was left alone as asked. Signing is
    /// not what decides it -- both copies were ad-hoc -- which is worth knowing,
    /// because it is the likely source of the claim that assessment mode only
    /// respects Developer ID-signed apps. It also means a debug build run from a
    /// build directory cannot keep its own icon; install it first.
    static func conceal(allowing allowed: Set<String>,
                        completion: @escaping (Result<Token, Error>) -> Void) {
        guard isAvailable, let classes = classes else {
            completion(.failure(Failure.unavailable))
            return
        }
        guard !simulatesFailure else {
            completion(.failure(Failure.rejected("simulated with --simulate-failure")))
            return
        }
        let allowed = allowed.sorted()

        guard let configuration = (classes.configuration.alloc() as AnyObject)
                .perform(configureSelector, with: systemItems, with: allowed as NSArray)?
                .takeUnretainedValue(),
              let assertion = (classes.assertion.alloc() as AnyObject)
                .perform(NSSelectorFromString("init"))?
                .takeUnretainedValue()
        else {
            completion(.failure(Failure.unavailable))
            return
        }

        Log.sections.log("activating assertion: allowing \(allowed.count) apps")

        var settled = false
        let handler: @convention(block) (Any?) -> Void = { error in
            guard !settled else { return }
            settled = true
            if let error = error {
                _ = assertion.perform(invalidateSelector)
                completion(.failure(Failure.rejected(String(describing: error))))
            } else {
                completion(.success(Token(assertion: assertion)))
            }
        }
        _ = assertion.perform(activateSelector, with: configuration, with: handler)

        // Applying an assertion stalls MenuBarAgent for 100-150ms; three seconds
        // without an answer means it is not coming.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !settled else { return }
            settled = true
            _ = assertion.perform(invalidateSelector)
            completion(.failure(Failure.timedOut))
        }
    }

    enum Failure: LocalizedError {
        case unavailable
        case rejected(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: return "MenuBarClientCore assessment mode is unavailable"
            case let .rejected(detail): return "the assertion was rejected: \(detail)"
            case .timedOut: return "the assertion never answered"
            }
        }
    }
}
