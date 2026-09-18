//
//  UpdateCheck.swift
//  JustHide
//
//  Whether there is a newer JustHide than this one.
//
//  One unauthenticated GET to api.github.com for the latest release, the tag
//  compared with this bundle's version. Nothing is sent: no identifier, no
//  version, no query string -- the request is the same one anybody makes for
//  that page, and the answer is cached for a day.
//
//  Deliberately NOT an updater. It does not download, unpack or replace
//  anything; it says there is a new version and opens the page, or tells a
//  Homebrew install the one command that does the job. Replacing a running app
//  that holds a concealment assertion is the cask's business (it quits the app
//  first, which is why `uninstall quit:` is in there), and an in-app updater
//  would need Sparkle, a signing key and an appcast to do it safely.
//

import Cocoa

enum UpdateCheck {
    static let repository = "benjustjammin/justhide"

    static var projectPage: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    private static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    enum State {
        case unknown
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    private(set) static var state: State = .unknown {
        didSet { NotificationCenter.default.post(name: .justHideUpdateChanged, object: nil) }
    }

    /// A check runs at most once a day unless asked for by hand, so opening
    /// Settings repeatedly does not hammer the API (which allows 60 requests an
    /// hour per address, shared with everything else on the network).
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"

    static func checkIfDue(force: Bool = false) {
        guard force || Settings.checksForUpdates else { return }
        if case .checking = state { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        if !force, let last = last, Date().timeIntervalSince(last) < interval {
            // Nothing new to learn today, but Settings should still show what
            // the last check found -- including that it found nothing newer,
            // which is the answer people actually want to see.
            if let known = Settings.latestSeenVersion {
                state = isNewer(known, than: currentVersion)
                    ? .available(version: known, page: releasePage(for: known))
                    : .upToDate
            }
            return
        }

        state = .checking
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { finish(data: data, response: response, error: error) }
        }.resume()
    }

    private static func finish(data: Data?, response: URLResponse?, error: Error?) {
        if let error = error {
            Log.controller.error("update check failed: \(error.localizedDescription)")
            state = .failed("JustHide could not reach GitHub to check for a newer version.")
            return
        }
        guard let data = data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = payload["tag_name"] as? String
        else {
            Log.controller.error("update check: no usable answer from GitHub")
            state = .failed("GitHub did not say what the latest version is.")
            return
        }

        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        Settings.latestSeenVersion = version

        guard isNewer(version, than: currentVersion) else {
            Log.controller.log("update check: \(Self.currentVersion) is current (latest is \(version))")
            state = .upToDate
            return
        }
        let page = (payload["html_url"] as? String).flatMap(URL.init(string:))
            ?? releasePage(for: version)
        Log.controller.log("update check: \(version) is available")
        state = .available(version: version, page: page)
    }

    private static func releasePage(for version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)") ?? projectPage
    }

    /// Dotted-integer comparison, so 1.10 is newer than 1.9 -- which a string
    /// comparison gets backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The version to offer, or nil when this copy is the newest known.
    static var availableVersion: String? {
        if case let .available(version, _) = state { return version }
        return nil
    }

    static func openReleasePage() {
        if case let .available(_, page) = state {
            NSWorkspace.shared.open(page)
        } else {
            NSWorkspace.shared.open(projectPage)
        }
    }

    // MARK: - Homebrew

    /// A cask install should be updated with brew, not by dragging a new bundle
    /// over the top of the old one: brew knows to quit the running copy first,
    /// and it will otherwise report the app as outdated for ever.
    static var isHomebrewInstall: Bool {
        ["/opt/homebrew/Caskroom/justhide", "/usr/local/Caskroom/justhide"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    static let homebrewCommand = "brew upgrade --cask justhide"

    static func copyHomebrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(homebrewCommand, forType: .string)
    }
}
