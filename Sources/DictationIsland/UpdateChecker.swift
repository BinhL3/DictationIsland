import AppKit
import Foundation
import Observation

/// Checks GitHub Releases for a newer version, once a day and on demand. No package needed: one
/// HTTPS request to the public releases API, nothing about the user is sent. A newer release
/// shows on Home with a Download button for its DMG.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL?
    }

    private(set) var available: Release?
    private(set) var isChecking = false

    static let repository = "BinhL3/DictationIsland"
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "updateLastCheck"
    @ObservationIgnored private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Checks shortly after launch if a day has passed, then keeps checking daily while running.
    func start() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let due = Date().timeIntervalSince1970 - last > Self.interval
        Task {
            try? await Task.sleep(for: .seconds(10))
            if due { await check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in _ = await self?.check() }
        }
    }

    /// Returns the newer release, or nil if this is the latest (or GitHub couldn't be reached).
    @discardableResult
    func check() async -> Release? {
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".dmg") }.flatMap(URL.init(string:))
        let release = Release(version: version, page: page, download: dmg)
        available = Self.isNewer(version, than: Self.currentVersion) ? release : nil
        return available
    }

    /// Menu bar "Check for Updates…": says so either way.
    func checkInteractively() {
        Task {
            let release = await check()
            let alert = NSAlert()
            if let release {
                alert.messageText = "DictationIsland \(release.version) is available"
                alert.informativeText = "You have \(Self.currentVersion). Download the new version and drag it into Applications to replace this one; your settings and permissions carry over."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { download() }
            } else {
                alert.messageText = "You're up to date"
                alert.informativeText = "DictationIsland \(Self.currentVersion) is the latest version."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func download() {
        guard let available else { return }
        NSWorkspace.shared.open(available.download ?? available.page)
    }

    /// Numeric, component by component: 0.10.0 is newer than 0.9.1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
